#
# You may distribute this module under the same terms as perl itself

# POD documentation - main docs before the code

=head1 NAME

Bio::EnsEMBL::Pipeline::Tools::ExonUtils - 

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 CONTACT

ensembl-dev@ebi.ac.uk

=head1 APPENDIX

The rest of the documentation details each of the object
methods. Internal methods are usually preceded with a _

=cut


# Let the code begin...

package Bio::EnsEMBL::Pipeline::Tools::ExonUtils;

use vars qw(@ISA);
use strict;
use Bio::EnsEMBL::Utils::Exception qw(verbose throw warning info);


@ISA = qw();

sub new {
  my ($class, @args) = @_;
  my $self = bless {},$class;
  return $self;
}

=head2 _transfer_supporting_evidence

  Arg [1]   : Bio::EnsEMBL::Exon
  Arg [2]   : Bio::EnsEMBL::Exon
  Function  : transfers evidence from source exon to target exon and tracks whats been transfered to avoid duplication
  Returntype: nothing but target exon (exon 2) has addition evidence 
  Exceptions: none
  Caller    : 
  Example   : Bio::EnsEMBL::Pipeline::Tools::ExonUtils->_transfer_supporting_evidence

=cut



sub _transfer_supporting_evidence{
  my ($self, $source_exon, $target_exon) = @_;
  
  my @target_sf = @{$target_exon->get_all_supporting_features};
  #  print "target exon sf: \n";
  #  foreach my $tsf(@target_sf){ print STDERR $tsf; $self->print_FeaturePair($tsf); }
  
  #  print "source exon: \n";
 
  # keep track of features already transferred, so that we do not duplicate
  my %unique_evidence;
  my %hold_evidence;

 SOURCE_FEAT:
  foreach my $feat ( @{$source_exon->get_all_supporting_features}){
    next SOURCE_FEAT unless $feat->isa("Bio::EnsEMBL::FeaturePair");
    
    # skip duplicated evidence objects
    next SOURCE_FEAT if ( $unique_evidence{ $feat } );
    
    # skip duplicated evidence 
    if ( $hold_evidence{ $feat->hseqname }{ $feat->start }{ $feat->end }{ $feat->hstart }{ $feat->hend } ){
      #print STDERR "Skipping duplicated evidence\n";
      next SOURCE_FEAT;
    }

    #$self->print_FeaturePair($feat);
    
  TARGET_FEAT:
    foreach my $tsf (@target_sf){
      next TARGET_FEAT unless $tsf->isa("Bio::EnsEMBL::FeaturePair");
      
      if($feat->start    == $tsf->start &&
         $feat->end      == $tsf->end &&
         $feat->strand   == $tsf->strand &&
         $feat->hseqname eq $tsf->hseqname &&
         $feat->hstart   == $tsf->hstart &&
         $feat->hend     == $tsf->hend){
        
        #print STDERR "feature already in target exon\n";
        next SOURCE_FEAT;
      }
    }
    #print STDERR "from ".$source_exon->{'temporary_id'}." to ".$target_exon->{'temporary_id'}."\n";
    #$self->print_FeaturePair($feat);
    $target_exon->add_supporting_features($feat);
    $unique_evidence{ $feat } = 1;
    $hold_evidence{ $feat->hseqname }{ $feat->start }{ $feat->end }{ $feat->hstart }{ $feat->hend } = 1;
  }
}



=head2 _validate_Exon

  Arg [1]   : Bio::EnsEMBL::Exon
 Description: It will return false if for the exon:
              start < 0, or
              start > end, or
              start == end
            
  Returntype: 1 or 0
  Exceptions: gives warnings if checks are passed
  Caller    : 
  Example   : Bio::EnsEMBL::Pipeline::Tools::ExonUtils->_validate_Exon($exon);

=cut


sub _validate_Exon{
  my ($self, $exon) = @_;

  if($exon->start < 0 ){
    my $msg = "rejecting exon, start < 0 : " . $exon->start . "\n";
    #warning($msg);
    return 0;
  }
  elsif($exon->start > $exon->end){
    my $msg = "rejecting exon, start > end : " . $exon->start . " > " . $exon->end . " ".$exon->dbID."\n";
    warning($msg);
    return 0;
  }
  #elsif($exon->start == $exon->end){
  #  my $msg = "naughty exon, start == end : " . $exon->start . " == " . $exon->end . " - rejecting it\n";
  #  print "Exon ".$exon->dbID." ".$exon->slice->seq_region_name."\n";
  #  warning($msg);
  #  return 0;
  #}
  return 1;
}


=head2 print methods

  Arg [1]   : Bio::EnsEMBL::Exon
  Function  : prints info about the exon or the exon and its evidence
  Returntype: none
  Exceptions: none
  Caller    : 
  Example   : 

=cut



sub _print_Exon{
  my ($self, $exon) = @_;

  my $id;
  if($exon->stable_id){
    $id = $exon->stable_id;
  }elsif($exon->dbID){
    $id = $exon->dbID;
  }else{
    $id = "no id";
  }
  print STDERR "Exon: ".$id."\n";
  $self->print_gff($exon);
}

sub _print_Evidence{
  my ($self, $exon) = @_;

  my $id;
  if($exon->stable_id){
    $id = $exon->stable_id;
  }elsif($exon->dbID){
    $id = $exon->dbID;
  }else{
    $id = "no id";
  }

  my @evidence = @{$exon->get_all_supporting_features};

  print STDERR "Exon: ".$id."\n"; 
  $self->print_gff($exon);
  foreach my $sf(@evidence){
    $self->print_gff($sf->gffstring);
  }

}

############################################################

sub _clone_Exon{
  my ($self,$exon) = @_;
  my $newexon = new Bio::EnsEMBL::Exon;
  $newexon->start      ($exon->start);
  $newexon->end        ($exon->end);
  $newexon->phase      ($exon->phase);
  $newexon->end_phase  ($exon->end_phase);
  $newexon->strand     ($exon->strand);
  $newexon->dbID       ($exon->dbID);
  $newexon->contig     ($exon->contig);
  $newexon->seqname    ($exon->seqname);
  $newexon->analysis   ($exon->analysis);

  if ( defined( $exon->stable_id ) ){
      $newexon->stable_id( $exon->stable_id );
      $newexon->created( $exon->created );
      $newexon->modified( $exon->modified );
      $newexon->version( $exon->version );
  }

   my %evidence_hash;
  foreach my $sf ( @{$exon->get_all_supporting_features} ){
    if ( $evidence_hash{$sf->hseqname}{$sf->hstart}{$sf->hend}{$sf->start}{$sf->end} ){
      next;
    }
    $evidence_hash{$sf->hseqname}{$sf->hstart}{$sf->hend}{$sf->start}{$sf->end} = 1;
    eval{
      $newexon->add_supporting_features( $sf );
    };
    if ( $@ ){
      print STDERR "_clone_Exon: problem transferring the supporting evidence\n";
    }
  }
  return $newexon;
}



sub print_gff{
  my ($self, $feature) = @_;

  my $id = $feature->dbID;
  if(!$id){
    $id = '*';
  }
  my $score = $feature->score;
  if(!$score){
    $score = 100;
  }
  my $str = $id."\t";
  $str .= "feature\t";
  $str .= $feature->start."\t";
  $str .= $feature->end."\t";
  $str .= $score."\t";
  $str .= $feature->strand."\t";
  
  print STDERR $str."\n";
}


1;
