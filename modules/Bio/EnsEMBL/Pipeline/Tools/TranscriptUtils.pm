#
# You may distribute this module under the same terms as perl itself

# POD documentation - main docs before the code

=head1 NAME

Bio::EnsEMBL::Pipeline::Tools::TranscriptUtils - 

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 CONTACT

ensembl-dev@ebi.ac.uk

=head1 APPENDIX

The rest of the documentation details each of the object
methods. Internal methods are usually preceded with a _

=cut


# Let the code begin...

package Bio::EnsEMBL::Pipeline::Tools::TranscriptUtils;

use vars qw(@ISA);
use strict;

use Bio::EnsEMBL::Root;
use Bio::EnsEMBL::Transcript;
use Bio::EnsEMBL::Exon;
use Bio::EnsEMBL::Pipeline::Runnable::Protein::Seg;
use Bio::EnsEMBL::DnaPepAlignFeature;
use Bio::EnsEMBL::Pipeline::Tools::ExonUtils;
use Bio::EnsEMBL::Utils::PolyA;
use Bio::EnsEMBL::DBSQL::SliceAdaptor;
use Bio::EnsEMBL::PredictionTranscript;

@ISA = qw(Bio::EnsEMBL::Root);

 



###########################################################
#
# METHODS DOING CHECKS
#
###########################################################

# parameter slice is optional. It makes sense to use it when working on fixed length slices.
# If it is not used, the method can still be used to check consistency of the transcript
# although always on chromosomal/slice coordinates, never in rawcontig coordinates.
# note - intron lengths now checked separately using _check_introns

sub _check_Transcript{
  my ($self,$transcript, $slice) = @_;

  # hardcoded stuff, to go in a config file
  my $MAX_EXON_LENGTH   = 20000;
  my $UNWANTED_EVIDENCE = "NG_";
  my $MAX_INTRON_LENGTH = 200000;
  my $id = $self->transcript_id( $transcript );
  my $valid = 1;
  my $strand;

  $transcript->sort;
  my @exons = @{$transcript->get_all_Exons};
  eval {
    $strand =  $exons[0]->strand;
  };
  if ($@) {
    $self->throw;
  }

  ############################################################
  # check that transcripts are not completely outside the slice
  # allow transcripts that fall partially off the slice only at 
  # one end, the 'higher' end of the slice
  ############################################################
  if ( $slice ){

    if ( $transcript->start > $slice->length || $transcript->end < 1 ){
      print STDERR "check: transcript $id outside the slice\n";
      $valid = 0;
    }
    elsif ( $transcript->start < 1 && $transcript->end > 1 ){
      #print STDERR "check: transcript $id falls off the slice by its lower end\n";
      $valid = 0;
    }
  }

  if (scalar(@exons) > 1 ) {
  EXON:
    for (my $i = 0; $i <= $#exons; $i++) {

      # check exon coords are valid
      if (! Bio::EnsEMBL::Pipeline::Tools::ExonUtils->_validate_Exon($exons[$i])){
	$valid = 0;
	last EXON;
      }

      # check exon length
      my $length = $exons[$i]->end - $exons[$i]->start + 1;
      if ( $length > $MAX_EXON_LENGTH ){
	print STDERR "check: exon too long: length = $length >  MAX_EXON_ENGTH = $MAX_EXON_LENGTH\n";
	$valid = 0;
	last EXON;
      }

      if ( $i>0 ){
	# check strand consistency:
	if($exons[$i]->strand != $exons[$i-1]->strand){
	  print STDERR "check: transcript $id has mixed strands\n";
	  $valid = 0;
	  last EXON;
	}

	# check phase consistency:
	if ( $exons[$i-1]->end_phase != $exons[$i]->phase  ){
	  #print STDERR "check: transcript $id has phase inconsistency\n";
	  $valid = 0;
	  last EXON;
	}
		
	# check for folded transcripts
	if ($exons[0]->strand == 1) {
	  if ($exons[$i]->start < $exons[$i-1]->end) {
	    print STDERR "check: transcript $id folds back on itself\n";
	    $valid = 0;
	    last EXON;
	  }
	}
	elsif ($exons[0]->strand == -1) {
	  if ($exons[$i]->end > $exons[$i-1]->start) {
	    print STDERR "check: transcript $id folds back on itself\n";
	    $valid = 0;
	    last EXON;
	  }
	}
      }
      # we don't want the NG_ entries going through, they are evil
      if($exons[$i]->get_all_supporting_features){
	foreach my $evidence (@{$exons[$i]->get_all_supporting_features}){
	  if ( $evidence->hseqname =~/$UNWANTED_EVIDENCE/ ){
	    print STDERR "check: transcript with evil evidence: ".$evidence->hseqname." skippping\n";
	    $valid = 0;
	    last EXON;
	  }
	}
      }
    }
  }
  elsif( scalar(@exons) == 1 ){
    my $length =  $exons[0]->end - $exons[0]->start + 1;
    if ( $length >  $MAX_EXON_LENGTH ){
      print STDERR "check: single exon transcript is too long: length = $length >  MAX_EXON_LENGTH = $MAX_EXON_LENGTH\n";
      $valid = 0;
    }
  }
  else{
    print STDERR "check: transcript with no exons\n";
    $valid = 0;
  }
  if ($valid == 0 ){
  }
  return $valid;
}


# parameter slice is optional. It makes sense to use it when 
# working on fixed length slices.
# If it is not used, the method can still be used to check consistency of the transcript
# although always on chromosomal/slice coordinates, never in rawcontig coordinates.

sub _check_introns{
    my ($self,$transcript, $slice, $maxintron) = @_;
    
    # hardcoded stuff, to go in a config file
    my $MAX_INTRON_LENGTH = $maxintron || 200000;
    
    #my $MAX_INTRON_LENGTH = 25000;

    my $id = $self->transcript_id( $transcript );
    my $valid = 1;
    
    my @exons = @{$transcript->get_all_Exons};
    
    my $strand;
    
    eval {
      $strand =  $exons[0]->strand;
    };
    if ($@) {
      $self->throw("Can't get strand\n");
    }

    #my $strand =  $transcript->start_Exon->strand;

 
    
    ############################################################
    # check that transcripts are not completely outside the slice
    # allow transcripts that fall partially off the slice only at 
    # one end, the 'higher' end of the slice
    ############################################################
    if ( $slice ){
      if ( $transcript->start > $slice->length || $transcript->end < 1 ){
        #print STDERR "transcript $id outside the slice\n";
        $valid = 0;
      }elsif ( $transcript->start < 1 && $transcript->end > 1 ){
        #print STDERR "transcript $id falls off the slice by its lower end\n";
        $valid = 0;
      }
    }
    

    #my @exons = @{$transcript->get_all_Exons};

    if(scalar(@exons) == 0)   {
      print STDERR "transcript with no exons\n";
      $valid = 0;
    }
    elsif (scalar(@exons) > 1 ) {
      
    EXON:
      for (my $i = 0; $i <= $#exons; $i++) {
	
	##############################
	# check intron length
	##############################
	if ( $strand == 1 ){
	  my $intron_length = $exons[$i]->start - $exons[$i-1]->end -1;
	  if ( $intron_length > $MAX_INTRON_LENGTH ){
	    print STDERR "intron too long: length = $intron_length >  MAX_INTRON_ENGTH = $MAX_INTRON_LENGTH\n";
	    $valid = 0;
	    last EXON;
	  }
	}
	elsif( $strand == -1 ){
	  my $intron_length = $exons[$i-1]->start - $exons[$i]->end -1;
	  if ( $intron_length > $MAX_INTRON_LENGTH ){
	    print STDERR "intron too long: length = $intron_length >  MAX_INTRON_ENGTH = $MAX_INTRON_LENGTH\n";
	    $valid = 0;
	    last EXON;
	  }
	}
      }
    }
      
    if ($valid == 0 ){
      #$self->_print_Transcript($transcript);
    }
    return $valid;
  }


############################################################
# this is a set of checks for transcripts where they are based
# on rawcontig coordinates

sub _check_rawcontig_Transcript{
    my ($self,$transcript) = @_;
    
    # hardcoded stuff, to go in a config file
    my $MAX_EXON_LENGTH   = 20000;
    my $UNWANTED_EVIDENCE = "NG_";
    
    my $id = $self->transcript_id( $transcript );
    my $valid = 1;
    
    my $strand =  $transcript->start_Exon->strand;

    my @exons = @{$transcript->get_all_Exons};
    
    if (scalar(@exons) > 1 ) {
	
      EXON:
	for (my $i = 0; $i <= $#exons; $i++) {
	    
	    ##############################
	    # check exon length
	    ##############################
	    my $length = $exons[$i]->end - $exons[$i] + 1;
	    if ( $length > $MAX_EXON_LENGTH ){
		print STDERR "exon too long: length = $length >  MAX_EXON_ENGTH = $MAX_EXON_LENGTH\n";
		$valid = 0;
		last EXON;
	    }
	    
	    ############################################################
	    # we don't want the NG_ entries going through, they are evil
	    ############################################################
	    foreach my $evidence (@{$exons[$i]->get_all_supporting_features}){
		if ( $evidence->hseqname =~/$UNWANTED_EVIDENCE/ ){
		    print STDERR "transcript with evil evidence: ".$evidence->hseqname." skippping\n";
		    $valid = 0;
		    last EXON;
		}
	    }
	    
	}
	
    }
    elsif( scalar(@exons) == 1 ){
	my $length =  $exons[0]->end - $exons[0]->start + 1;
	if ( $length >  $MAX_EXON_LENGTH ){
	    print STDERR "single exon transcript is too long: length = $length >  MAX_EXON_LENGTH = $MAX_EXON_LENGTH\n";
	    $valid = 0;
	}
    }
    else{
	print STDERR "transcript with no exons, skipping\n";
	$valid = 0;
    }
    if ($valid == 0 ){
	$self->_print_Transcript($transcript);
    }
    return $valid;
}

############################################################

=head2 _check_Translation

Description : it returns TRUE if a transcript has a translation, and this has
              no  stop codons. It returns FALSE otherwise.
  IMPORTANT : we want to check translation independently from other
              properties of the transcripts. Basically because
              we may have some transcripts whih are valid but
              for which we haven not assigned a translation yet.
ReturnType  : a BOOLEAN.
=cut

sub _check_Translation{
  my ($self,$transcript) = @_;
  my $id = $self->transcript_id( $transcript );
  my $valid = 1;
  my $translation = $transcript->translation;

  # double check sane translation start & end
  if( $translation->start < 1){
    print STDERR "dodgy translation start: " . $translation->start . "\n";
    $valid = 0;
  }

  if( $translation->end < 1 || $translation->end > $translation->end_Exon->length ){
    print STDERR "dodgy translation end: " . $translation->end . " end-exon length: " .
      $translation->end_Exon->length . "\n";
    $valid = 0;
  }

  my $sequence;
  eval{
    $sequence = $transcript->translate;
  };
  unless ( $sequence ){
    print STDERR "transcript $id has no translation\n";
    return 0;
  }
  if ( $sequence ){
    my $peptide = $sequence->seq;
    # report terminal stops
    if($peptide =~ /\*$/){
      print STDERR "translation of transcript $id terminates in a stop\n";
      $peptide =~ s/\*$//;
    }

    # check for internal stops
    if ( $peptide =~ /\*/ ){
      print STDERR "translation of transcript $id has STOP codons\n";
      $valid = 0;
    }
  }

  return $valid;
}

############################################################
=head2 _check_low_complexity

  Arg [1]   : Bio::EnsEMBL::Transcript $transcript
  Arg [2]   : int $complexity_threshold
  Function  : uses seg to find low complexity regions in transcript->translate. 
              Calculates overall %low complexity of the translation and compares to 
              $complexity_threshold. A valid transcript has calculated low complexity 
              is less than $complexity_threshold
  Returntype: 1/0
  Exceptions: warns if things checks fail and returns 0
  Caller    : 
  Example   : 

=cut
	  
sub _check_low_complexity{
  my ($self, $transcript,$complexity_threshold) = @_;
  my $valid = 1;
 
  
  eval{
    
    my $protseq = $transcript->translate;
    
    # Ugh! 
    my $analysis = Bio::EnsEMBL::Analysis->new(
					       -db           => 'low_complexity',
					       -program      => '/usr/local/ensembl/bin/seg',
					       -program_file => '/usr/local/ensembl/bin/seg',
					       -gff_source   => 'Seg',
					       -gff_feature  => 'annot',
					       -module       => 'Seg',
					       -logic_name   => 'Seg'
					       
					      );
    
    my $seg = new  Bio::EnsEMBL::Pipeline::Runnable::Protein::Seg(    
								  -query    => $protseq,
								  -analysis => $analysis,
								 );
    
    $seg->run;
    
    my $low_complexity = $seg->get_low_complexity_length;
    print STDERR "Have low complexity ".$low_complexity.
      " and complexity threshold $complexity_threshold\n";
    if($low_complexity > $complexity_threshold){
      warn("discarding transcript - translation has $low_complexity% low complexity sequence\n");
      $valid = 0;
    }
    
    
  };
  
  if($@){
    print STDERR "problem running seg: \n[$@]\n";
    $valid = 1;		# let transcript through
  }
  
  return $valid;

}

############################################################

sub transcript_id {
  my ( $self, $t ) = @_;
  my $id;
  if ( $t->stable_id ){
    $id = $t->stable_id;
  }
  elsif( $t->dbID ){
    $id = $t->dbID;
  }
  elsif( $t->temporary_id ){
    $id = $t->temporary_id;
  }
  else{
    $id = 'no-id';
  }
  
  if ($t->type){
      $id .= " ".$t->type;
  }
  return $id;
}

############################################################

=head2 split_Transcript

  Arg[1]    : Bio::EnsEMBL::Transcript $transcript
  Arg[2]    : int $max_intron
  Function  : splits $transcript into multiple transcripts at introns that exceed $max_intron. 
              Rejects single exon transcripts that result. 
  ReturnType: undef/Ref to @Bio::EnsEMBL::Transcript
  Exceptions: warns and returns undef if $transcript is not a Bio::EnsEMBL::Transcript

=cut
    
sub split_Transcript{
  my ($self, $transcript, $max_intron) = @_;
  
 
  
  my @split_transcripts   = ();
  
  if(!($transcript->isa("Bio::EnsEMBL::Transcript"))){
    $self->warn("[$transcript] is not a Bio::EnsEMBL::Transcript - cannot split");
    return undef;
  }
  
  my $prev_exon;
  my $exon_added = 0;
  
  my $curr_transcript = new Bio::EnsEMBL::Transcript;
  my $translation     = new Bio::EnsEMBL::Translation;
  
  $curr_transcript->translation($translation);
  
 EXON: foreach my $exon (@{$transcript->get_all_Exons}){
    
    $exon_added = 0;
    
    # Start a new transcript if we are just starting out
    
    if($exon == $transcript->start_Exon){
      
      $prev_exon = $exon;
      
      $curr_transcript->add_Exon($exon);
      $exon_added = 1;
      $curr_transcript->translation->start_Exon($exon);
      $curr_transcript->translation->start($transcript->translation->start);
      
      push(@split_transcripts, $curr_transcript);
      next EXON;
    }

    if ($exon->strand != $prev_exon->strand){
      print STDERR "strand mismatch - cannot split\n";
      return ($transcript); # original transcript
    }

    # We need to start a new transcript if the intron size between $exon and $prev_exon is too large
    my $intron = 0;
    
    if ($exon->strand == 1) {
      $intron = abs($exon->start - $prev_exon->end - 1);
    } else {
      $intron = abs($prev_exon->start - $exon->end - 1);
    }
    
    if ($intron > $max_intron) {
      $curr_transcript->translation->end_Exon($prev_exon);
      $curr_transcript->translation->end($prev_exon->end - $prev_exon->start + 1 - $prev_exon->end_phase);
      
      my $t  = new Bio::EnsEMBL::Transcript;
      my $tr = new Bio::EnsEMBL::Translation;
      
      $t->translation($tr);
      
      # add exon unless already added, and set translation start and start_Exon
      # But the exon will nev er have been added ?
      
      $t->add_Exon($exon) unless $exon_added;
      $exon_added = 1;
      
      $t->translation->start_Exon($exon);
      
      if ($exon->phase == 0) {
	$t->translation->start(1);
      } elsif ($exon->phase == 1) {
	$t->translation->start(3);
      } elsif ($exon->phase == 2) {
	$t->translation->start(2);
      }
      
      $exon->phase(0);
      
      $curr_transcript = $t;
      
      push(@split_transcripts, $curr_transcript);
    }
    
    if ($exon == $transcript->end_Exon){
      $curr_transcript->add_Exon($exon) unless $exon_added;
      $exon_added = 1;
      
      $curr_transcript->translation->end_Exon($exon);
      $curr_transcript->translation->end($transcript->translation->end);
    } else {
      $curr_transcript->add_Exon($exon) unless $exon_added;
    }
    
    foreach my $sf(@{$exon->get_all_supporting_features}){
      $sf->seqname($exon->slice->name);
    }
    
    $prev_exon = $exon;
    
  }
  
  # discard any single exon transcripts
  my @final_transcripts = ();
  my $count = 1;
  
  foreach my $st (@split_transcripts){
   
    
    my @ex = @{$st->get_all_Exons};
    
    if(scalar(@ex) > 1){
      $st->{'temporary_id'} = $transcript->dbID . "." . $count;
      $count++;
      push(@final_transcripts, $st);
      
    }
  }
  
  return \@final_transcripts;
  
}
############################################################
#
# METHODS DOING THE PRINTING
#
############################################################

sub _print_SimpleTranscript{
    my ($self,$transcript,$chr_coord) = @_;
    my @exons = sort { $a->start <=> $b->start } @{$transcript->get_all_Exons};
    my $id;
    if ($transcript->stable_id){
	$id = $transcript->stable_id;
    }
    elsif ( $transcript->dbID ){
	$id = $transcript->dbID;
    }
    else{
      $id = "no id";
    }
    if ( defined( $transcript->type ) ){
      $id .= " ".$transcript->type;
    }
    print STDERR "transcript ".$id.": ";
    

    
    my $shift = 0;
    if ( $chr_coord ){
      $shift = $exons[0]->slice->start - 1;
    }
    foreach my $exon ( @exons){
      print STDERR ($exon->start + $shift)."-".( $exon->end + $shift )." ";
    }
    print STDERR "\n";
  }

############################################################

sub _print_Transcript{
  my ($self,$transcript) = @_;

  my @exons = @{$transcript->get_all_Exons};
  my $id;
  if ($transcript->stable_id){
    $id = $transcript->stable_id;
  }
  elsif ( $transcript->dbID ){
    $id = $transcript->dbID;
  }
  else{
    $id = "no id";
  }
  if ( defined( $transcript->type ) ){
    $id .= " ".$transcript->type;
  }
 
  print STDERR "transcript: ".$id."\n";
  foreach my $exon ( @exons){
    print STDERR $exon->start." ".$exon->end." ".$exon->strand."\n";
  }
  if ( $transcript->can('translation') && $transcript->translation){
    $self->_print_Translation($transcript);
  }
}

############################################################

sub _print_Translation{
  my ($self,$transcript) = @_;
  
  my $translation = $transcript->translation;
  
  return unless $translation;
  if ( $translation->start_Exon ){
      print STDERR "translation start exon: ".
	  $translation->start_Exon->start."-".$translation->start_Exon->end.
	      " start: ".$translation->start."\t phase: ".$translation->start_Exon->phase.
		  " end_phase: ".$translation->start_Exon->end_phase."\n";
  }
  else{
      print STDERR "translation->start_Exon does not exist\n";
  }

  if ( $translation->end_Exon ){
      print STDERR "translation end exon: ".
	  $translation->end_Exon->start."-".$translation->end_Exon->end.
	      " end: ".$translation->end."\t phase: ".$translation->end_Exon->phase.
		  " end_phase: ".$translation->end_Exon->end_phase."\n";
  }
  else{
      print STDERR "translation->end_Exon does not exist\n";
  }

  my $sequence; 
  eval{ 
    $sequence = $transcript->translate; 
  }; 
  if ( $sequence ){ 
    my $peptide = $sequence->seq; 
    print STDERR "peptide: $peptide\n"; 
  } 
}

############################################################

sub _print_Evidence{
  my ($self,$transcript) = @_;
  my @exons = @{$transcript->get_all_Exons};
  my $id;
  if ($transcript->stable_id){
    $id = $transcript->stable_id;
  }
  elsif ( $transcript->dbID ){
    $id = $transcript->dbID;
  }
  else{
    $id = "no id";
  }
  if ( defined( $transcript->type ) ){
    $id .= " ".$transcript->type;
  }
  print STDERR "transcript: ".$id."\n";
  my $count = 0;
  foreach my $exon ( @exons){
    $count++;
    my $exon_id;
    if ($exon->stable_id){
      $exon_id = $exon->stable_id;
    }
    elsif ( $exon->dbID ){
      $exon_id = $exon->dbID;
    }
    else{
      $exon_id = "no id";
    }
    my $exon_info = feature_info($exon_id, $exon);
    print STDERR "Exon $exon_info\n";
    my @evidence = @{$exon->get_all_supporting_features};
    if (@evidence){
      foreach my $evi ( @evidence ){
        my $evi_info = feature_info('', $evi);
        print STDERR "Evidence: ".$evi_info."\n";
      }
    }	
    else{
      print STDERR "no evidence for exon ".$count."\n";
    }
  }
}

############################################################

sub _print_TranscriptEvidence{
  my ($self,$transcript) = @_;
  my @exons = @{$transcript->get_all_Exons};
  my %evidence;
  my %score;
  my %percent_id;
  foreach my $exon ( @exons){
    my @evidences = @{$exon->get_all_supporting_features};
    if (@evidences){
      foreach my $evi ( @evidences ){
	$evidence{$evi->hseqname} = 1;
	unless( $score{$evi->hseqname} ){
	  $score{$evi->hseqname} = $evi->score;
	}
	if ( $score{$evi->hseqname} < $evi->score ){
	  $score{$evi->hseqname} = $evi->score;
	}
	unless( $percent_id{$evi->hseqname} ){
	  $percent_id{$evi->hseqname} = $evi->percent_id;
	}
	if ( $percent_id{$evi->hseqname} < $evi->percent_id ){
	  $percent_id{$evi->hseqname} = $evi->percent_id;
	}
      }
    }
  }
  foreach my $evidence ( keys %evidence ){
    print STDERR "hit_name: ".$evidence." score: ".$score{$evidence}." percent_id: ".$percent_id{$evidence}."\n";
  }
}

############################################################

sub _print_Peptide{
  my ($self, $transcript) = @_;
  
  my $seqout = new Bio::SeqIO->new(-fh => \*STDERR);
  my $translation;
  
  eval {
    $translation = $transcript->translate;
    print "translation is a $translation\n";
  };  
  if ($@) {
    print STDERR "Couldn't translate transcript\n";
  }
  else{
    #unless ( $translation->display_id ){
    #  $translation->display_id($self->transcript_id($transcript));
    #}
    $seqout->write_seq($translation);
  }
}

############################################################

sub _clone_Transcript{
  my ($self,$transcript) = @_;
  
  #print STDERR "Cloning:\n";
  #$self->_print_Transcript($transcript);
  my $newtranscript  = new Bio::EnsEMBL::Transcript;
  my $newtranslation = new Bio::EnsEMBL::Translation;
  
  my $translation_start_exon;
  my $translation_end_exon;

  if ( defined $transcript->translation ){
    $translation_start_exon = $transcript->translation->start_Exon;
    $translation_end_exon   = $transcript->translation->end_Exon; 
  }

  foreach my $exon ( @{$transcript->get_all_Exons} ){
    my $newexon = Bio::EnsEMBL::Pipeline::Tools::ExonUtils->_clone_Exon($exon);
    if ( defined $transcript->translation ){
      if ($exon == $translation_start_exon){
	$newtranslation->start_Exon($newexon);
	$newtranslation->start($transcript->translation->start);
      }
      if ($exon == $translation_end_exon){
	$newtranslation->end_Exon($newexon);
	$newtranslation->end($transcript->translation->end);
      }
    }
    
    $newtranscript->add_Exon($newexon);
  }
  #$newtranscript->sort;
  #$newtranscript->dbID($transcript->dbID);
  if (defined $transcript->type ){
    $newtranscript->type($transcript->type);
  }
  if ( defined $transcript->stable_id ){
      $newtranscript->stable_id( $transcript->stable_id );
      $newtranscript->version( $transcript->version );
  } 
  if ( defined $transcript->translation ){
    $newtranscript->translation($newtranslation);
  }
  return $newtranscript;
}

############################################################

=head2 find_transcripts_by_protein_evidence
  
  Method to get all the transcripts in a given database that
  have a given protein evidence

=cut

sub find_transcripts_by_protein_evidence{
  my ($self,$id,$db,$type) = @_;
  
  my @tranz;
  
  my $pfa_sql = qq(SELECT protein_align_feature_id 
		   FROM protein_align_feature 
		   WHERE hit_name = ?);
  my $pfa_sth = $db->prepare($pfa_sql);
  my $pf_id;
  $pfa_sth->execute($id);
  $pfa_sth->bind_columns(\$pf_id);
  my @id_array;
  
  while($pfa_sth->fetch){
    push(@id_array, $pf_id);
  }
  my $id_list = join(',',@id_array);
  
  if ($id_list){
    my $transcript_sql;
    $transcript_sql = "SELECT distinct(t.transcript_id) ". 
      "FROM transcript t, exon_transcript et, exon e, ".
	"supporting_feature sf ";
    $transcript_sql .= ", gene g " if($type);
    $transcript_sql .= "WHERE  sf.feature_id in (".$id_list.") and ".
      "e.exon_id=et.exon_id and et.transcript_id=t.transcript_id and ".
	"sf.exon_id=e.exon_id and sf.feature_type= 'protein_align_feature' ";
    $transcript_sql .= "and t.gene_id = g.gene_id and g.type = '$type'" if($type);
    
    #print STDERR $transcript_sql."\n";
    my $transcript_sth = $db->prepare($transcript_sql);
    
    $transcript_sth->execute;
    
    my $transcript_id;
    
    $transcript_sth->bind_columns(\$transcript_id);

    
    while($transcript_sth->fetch){
      push(@tranz, $transcript_id);
    } 
  }
  
  
  my $t_adaptor = $db->get_TranscriptAdaptor;
  my $s_adaptor = $db->get_SliceAdaptor;
  
  ############################################################
  # create transcripts in slice coordinates
  my @transcripts;
  #print STDERR "have ".@tranz." transcript ids\n";
  foreach my $t_id ( @tranz ){
    my $tran     = $t_adaptor->fetch_by_dbID($t_id);
    my $slice    = $s_adaptor->fetch_by_transcript_id($tran->dbID);
    my $big_slice = $slice;
    $big_slice->expand(1, $big_slice->seq_region_length);
    my $fakegene = Bio::EnsEMBL::Gene->new();
    $fakegene->add_Transcript( $tran );
    my $tmp_gene = $fakegene->transform( $big_slice );
    my @trans = @{$tmp_gene->get_all_Transcripts};
    push ( @transcripts, $trans[0] );
  }
  
  return @transcripts;
}

############################################################

=head2 find_transcripts_by_dna_evidence
  
  Method to get all the transcripts in a given database that
  have a given dna (cdna/est) evidence

=cut

sub find_transcripts_by_dna_evidence{
  my ($self,$id,$db, $type) = @_;

  ############################################################
  # strip down the version number
  if ( $id =~/(\S+)\.\d+/ || $id =~/(\w+_*\d+)\.\d+/ ){
    $id = $1;
  }
  
  my @tranz;
  
  my $q = qq( SELECT dna_align_feature_id FROM dna_align_feature WHERE hit_name like "$id\%" );
  
    my $sth = $db->prepare($q) || $db->throw("can't prepare: $q");
  my $res = $sth->execute || $db->throw("can't execute: $q");
    
  my @id_array;  
  while( my ($df_id) =  $sth->fetchrow_array) {
    push(@id_array, $df_id);
  }
  my $id_list = join(',',@id_array);
  
  if ( $id_list ){
    my $transcript_sql;
    $transcript_sql = "SELECT distinct(t.transcript_id) FROM transcript t, exon_transcript et, exon e, supporting_feature sf ";
    $transcript_sql .= ", gene g " if($type);
    $transcript_sql .= "WHERE  sf.feature_id in (".$id_list.") and ".
      "e.exon_id=et.exon_id and et.transcript_id=t.transcript_id and ".
	"sf.exon_id=e.exon_id and sf.feature_type= 'dna_align_feature' ";
    $transcript_sql .= "and t.gene_id = g.gene_id and g.type = '$type'" if($type);
    
    my $transcript_sth = $db->prepare($transcript_sql);
    
    $transcript_sth->execute;
    
    my $transcript_id;
    
    $transcript_sth->bind_columns(\$transcript_id);
    
    while($transcript_sth->fetch){
      push(@tranz, $transcript_id);
    } 
  }
  my $t_adaptor = $db->get_TranscriptAdaptor;
  my $s_adaptor = $db->get_SliceAdaptor;
  
  ############################################################
  # create transcripts in slice coordinates
  my @transcripts;
  foreach my $t_id ( @tranz ){
      #print STDERR "found $t_id\n";
      my $tran     = $t_adaptor->fetch_by_dbID($t_id);
      my $slice    = $s_adaptor->fetch_by_transcript_id($tran->dbID);
      my $big_slice = $slice;
      $big_slice->expand(1, $big_slice->seq_region_length);
      my $fakegene = Bio::EnsEMBL::Gene->new();
      $fakegene->add_Transcript( $tran );
      my $tmp_gene = $fakegene->transform( $big_slice );
      my @trans = @{$tmp_gene->get_all_Transcripts};
      push ( @transcripts, $trans[0] );
  }
  
  return @transcripts;
}

############################################################

sub is_spliced{
  my ($self,$t) = @_;
  my @exons = @{$t->get_all_Exons};
  if ( scalar (@exons ) == 1 ){
    return 0;
  }
  elsif( scalar (@exons) > 1 ){
      
      # check that there are not funky frame shifts
      @exons = sort{ $a->start <=> $b->start } @exons;
      for(my $i=0; $i<$#exons; $i++){
	  my $intron = $exons[$i+1]->start - $exons[$i]->end - 1;
	  if ( $intron > 9 ){
	      return 1;
	  }
      }
      return 0;
  }
  else{
      return 0;
  }
}

sub _real_introns{
  my ($self,$tran) = @_;
  my @exons  = sort { $a->start <=> $b->start} @{$tran->get_all_Exons};
  my $real_introns = 0;
 INTRON:
  for (my $i=0; $i<$#exons; $i++ ){
    my $intron_start  = $exons[$i]->end + 1;
    my $intron_end    = $exons[$i+1]->start - 1;
    my $intron_length = $intron_end - $intron_start + 1;

    next INTRON unless ( $intron_length > 9 );
    $real_introns++;
  }
  return $real_introns;
}

############################################################

############################################################
# this method cehcks whether the splice sites are canonical
# it returns 1 if all splice sites are canonical.
# It returns zero if the transcrip has only 1 exon

sub check_splice_sites{
  my ($self, $transcript) = @_;

  $self->throw("no transcript passed in") unless defined $transcript;
  
  my $strand = $transcript->start_Exon->strand;
  my @exons  = @{$transcript->get_all_Exons};
  
  my $introns  = scalar(@exons) - 1 ; 
  if ( $introns <= 0 ){
    return 0;
  }
  
  my $correct  = 0;
  my $wrong    = 0;
  my $other    = 0;
  
  # all exons in the transcripts are in the same seqname coordinate system:
  my $slice = $transcript->start_Exon->slice;
  
  if ($strand == 1 ){
    
  INTRON:
    for (my $i=0; $i<$#exons; $i++ ){
      my $upstream_exon   = $exons[$i];
      my $downstream_exon = $exons[$i+1];
      my $upstream_site;
      my $downstream_site;

      ############################################################
      # consider only real introns
      my $intron_length = ( $exons[$i+1]->start - $exons[$i]->end - 1 );
      next if $intron_length <=9;

      eval{
	$upstream_site = 
	  $slice->subseq( ($upstream_exon->end     + 1), ($upstream_exon->end     + 2 ) );
	$downstream_site = 
	  $slice->subseq( ($downstream_exon->start - 2), ($downstream_exon->start - 1 ) );
      };
      unless ( $upstream_site && $downstream_site ){
	print STDERR "problems retrieving sequence for splice sites\n$@";
	next INTRON;
      }

      # case
      $upstream_site = uc($upstream_site);
      $downstream_site = uc($downstream_site);      

      print STDERR "check_splice_sites: upstream ".
	($upstream_exon->end + 1)."-".($upstream_exon->end + 2).": $upstream_site ".
	  "downstream ".($downstream_exon->start - 2 )."-". ($downstream_exon->start - 1 ).": $downstream_site\n";
      print STDERR "check_splice_sites: upstream $upstream_site, downstream: $downstream_site\n";
      ## good pairs of upstream-downstream intron sites:
      ## ..###GT...AG###...   ...###AT...AC###...   ...###GC...AG###.
      
      ## bad  pairs of upstream-downstream intron sites (they imply wrong strand)
      ##...###CT...AC###...   ...###GT...AT###...   ...###CT...GC###...
      
      if (  ($upstream_site eq 'GT' && $downstream_site eq 'AG') ||
	    ($upstream_site eq 'AT' && $downstream_site eq 'AC') ||
	    ($upstream_site eq 'GC' && $downstream_site eq 'AG') ){
	$correct++;
      }
      elsif (  ($upstream_site eq 'CT' && $downstream_site eq 'AC') ||
	       ($upstream_site eq 'GT' && $downstream_site eq 'AT') ||
	       ($upstream_site eq 'CT' && $downstream_site eq 'GC') ){
	$wrong++;
      }
      else{
	$other++;
      }
    } # end of INTRON
  }
  elsif ( $strand == -1 ){
    
    #  example:
    #                                  ------CT...AC---... 
    #  transcript in reverse strand -> ######GA...TG###... 
    # we calculate AC in the slice and the revcomp to get GT == good site
    
  INTRON:
    for (my $i=0; $i<$#exons; $i++ ){
      my $upstream_exon   = $exons[$i];
      my $downstream_exon = $exons[$i+1];
      my $upstream_site;
      my $downstream_site;
      my $up_site;
      my $down_site;

      ############################################################
      # consider only real introns
      my $intron_length = ( $exons[$i]->start - $exons[$i+1]->end - 1 );
      next if $intron_length <=9;

      eval{
	$up_site = 
	  $slice->subseq( ($upstream_exon->start - 2), ($upstream_exon->start - 1) );
	$down_site = 
	  $slice->subseq( ($downstream_exon->end + 1), ($downstream_exon->end + 2 ) );
      };
      unless ( $up_site && $down_site ){
	print STDERR "problems retrieving sequence for splice sites\n$@";
	next INTRON;
      }
      ( $upstream_site   = reverse(  $up_site  ) ) =~ tr/ACGTacgt/TGCAtgca/;
      ( $downstream_site = reverse( $down_site ) ) =~ tr/ACGTacgt/TGCAtgca/;
      
      # case
      $upstream_site = uc($upstream_site);
      $downstream_site = uc($downstream_site);

      print STDERR "check_splice_sites: upstream ".
	  ($upstream_exon->start - 2)."-".($upstream_exon->start - 1).": $upstream_site ".
	      "downstream ".($downstream_exon->end + 1)."-". ($downstream_exon->end + 2 ).": $downstream_site\n";
      if (  ($upstream_site eq 'GT' && $downstream_site eq 'AG') ||
	    ($upstream_site eq 'AT' && $downstream_site eq 'AC') ||
	    ($upstream_site eq 'GC' && $downstream_site eq 'AG') ){
	$correct++;
      }
      elsif (  ($upstream_site eq 'CT' && $downstream_site eq 'AC') ||
	       ($upstream_site eq 'GT' && $downstream_site eq 'AT') ||
	       ($upstream_site eq 'CT' && $downstream_site eq 'GC') ){
	$wrong++;
      }
      else{
	$other++;
      }
      
    } # end of INTRON
  }
  if ( $correct == $introns ){
    return 1;
  }
  else{
    return 0;
  }
}

############################################################
# this method checks whether the splice sites are canonical
# it returns 1 if all splice sites are canonical
# It returns zero if the transcrip has only 1 exon, or some of the splice sites
# are non-canonical

sub check_canonical_splice_sites{
  my ($self, $transcript) = @_;

  $self->throw("no transcript passed in") unless defined $transcript;
  $transcript->sort;

  my $strand = $transcript->start_Exon->strand;
  my @exons  = @{$transcript->get_all_Exons};

  my $introns  = scalar(@exons) - 1 ; 
  if ( $introns <= 0 ){
    return 0;
  }

  my $correct  = 0;
  my $wrong    = 0;
  my $other    = 0;

  # all exons in the transcripts are in the same seqname coordinate system:
  my $slice = $transcript->start_Exon->contig;

  if ($strand == 1 ){

  INTRON:
    for (my $i=0; $i<$#exons; $i++ ){
      my $upstream_exon   = $exons[$i];
      my $downstream_exon = $exons[$i+1];
      my $upstream_site;
      my $downstream_site;

      ############################################################
      # consider only real introns
      my $intron_length = ( $exons[$i+1]->start - $exons[$i]->end - 1 );

      next if $intron_length <=9;

      eval{
	$upstream_site = 
	  $slice->subseq( ($upstream_exon->end     + 1), ($upstream_exon->end     + 2 ) );
	$downstream_site = 
	  $slice->subseq( ($downstream_exon->start - 2), ($downstream_exon->start - 1 ) );
      };
      unless ( $upstream_site && $downstream_site ){
	print STDERR "problems retrieving sequence for splice sites\n$@";
	next INTRON;
      }

print STDERR "check_splice_sites: upstream ".
	  ($upstream_exon->end + 1)."-".($upstream_exon->end + 2).": $upstream_site ".
	      "downstream ".($downstream_exon->start - 2 )."-". ($downstream_exon->start - 1 ).": $downstream_site\n";
      print STDERR "check_splice_sites: upstream $upstream_site, downstream: $downstream_site\n";
      ## good pairs of upstream-downstream intron sites:
      ## ..###GT...AG###...   ...###AT...AC###...   ...###GC...AG###.

      ## bad  pairs of upstream-downstream intron sites (they imply wrong strand)
      ##...###CT...AC###...   ...###GT...AT###...   ...###CT...GC###...

      if (  ($upstream_site eq 'GT' && $downstream_site eq 'AG') ||
	    ($upstream_site eq 'AT' && $downstream_site eq 'AC') ||
	    ($upstream_site eq 'GC' && $downstream_site eq 'AG') ){
	$correct++;
      }
      elsif (  ($upstream_site eq 'CT' && $downstream_site eq 'AC') ||
	       ($upstream_site eq 'GT' && $downstream_site eq 'AT') ||
	       ($upstream_site eq 'CT' && $downstream_site eq 'GC') ){
	$wrong++;
	return 0;
      }
      else{
	$other++;
	return 0;
      }
    } # end of INTRON
  }
  elsif ( $strand == -1 ){

    #  example:
    #                                  ------CT...AC---... 
    #  transcript in reverse strand -> ######GA...TG###... 
    # we calculate AC in the slice and the revcomp to get GT == good site

  INTRON:
    for (my $i=0; $i<$#exons; $i++ ){
      my $upstream_exon   = $exons[$i];
      my $downstream_exon = $exons[$i+1];

      ############################################################
      # consider only real introns
      my $intron_length = ( $exons[$i]->start - $exons[$i+1]->end - 1 );
      #print STDERR "intron length: $intron_length\n";
      next if $intron_length <=9;

      my $upstream_site;
      my $downstream_site;
      my $up_site;
      my $down_site;
      eval{
	$up_site = 
	  $slice->subseq( ($upstream_exon->start - 2), ($upstream_exon->start - 1) );
	$down_site = 
	  $slice->subseq( ($downstream_exon->end + 1), ($downstream_exon->end + 2 ) );
      };
      unless ( $up_site && $down_site ){
	print STDERR "problems retrieving sequence for splice sites\n$@";
	next INTRON;
      }
      ( $upstream_site   = reverse(  $up_site  ) ) =~ tr/ACGTacgt/TGCAtgca/;
      ( $downstream_site = reverse( $down_site ) ) =~ tr/ACGTacgt/TGCAtgca/;
      
      print STDERR "check_splice_sites: upstream ".
	  ($upstream_exon->start - 2)."-".($upstream_exon->start - 1).": $upstream_site ".
	      "downstream ".($downstream_exon->end + 1)."-". ($downstream_exon->end + 2 ).": $downstream_site\n";
      if (  ($upstream_site eq 'GT' && $downstream_site eq 'AG') ||
	    ($upstream_site eq 'AT' && $downstream_site eq 'AC') ||
	    ($upstream_site eq 'GC' && $downstream_site eq 'AG') ){
	$correct++;
      }
      elsif (  ($upstream_site eq 'CT' && $downstream_site eq 'AC') ||
	       ($upstream_site eq 'GT' && $downstream_site eq 'AT') ||
	       ($upstream_site eq 'CT' && $downstream_site eq 'GC') ){
	$wrong++;
	return 0;
      }
      else{
	$other++;
	return 0;
      }
      
    } # end of INTRON
  }
  return 1;
}

#####
#######################################################
# method for putting the stop codon at the end of the translation
# if it is not already there. If the codon next to the last one is not a stop codon
# we leav it un-touched.

sub set_stop_codon{
  my ( $self, $transcript ) = @_;

  my  $verbose = 0;
  unless ( $transcript->translation ){
    print STDERR "transcript has no translation - cannot put the stops" if $verbose;
    return $transcript;
  }

  if ( $transcript->translation ){
    
    my $end      = $transcript->translation->end;
    my $end_exon = $transcript->translation->end_Exon;

    ############################################################
    # first see whether the transcript already include the stop:  taa/tag/tga 
    
    # this gives you the sequence 5' to 3'
    my $bioseq = $end_exon->seq; 
    #print STDERR "sequence length: ".$bioseq->length."\n";
    #print STDERR "last codon position: ".($end - 2)."..".$end."\n";
    my $last_codon;
    if ( $end > 2 ){
      $last_codon = $bioseq->subseq( $end - 2, $end );
    }
    else{
	my $donor    = 3 - $end;
	my $acceptor = $end;
	
	my $previous_exon = $self->get_previous_Exon( $transcript, $end_exon );
	if ($previous_exon ){
	    my $donor_seq =  
		$previous_exon->seq->subseq( $previous_exon->end - $previous_exon->start + 1 - $donor + 1, $previous_exon->end - $previous_exon->start + 1 );
	    my $acceptor_seq = 
		$end_exon->seq->subseq( 1, $end );
	    
	    $last_codon = $donor_seq.$acceptor_seq;
	}
    }
    if ( uc($last_codon) eq 'TAA' || uc($last_codon) eq 'TAG' || uc($last_codon) eq 'TGA' ){ 
	print STDERR "transcript already has a stop at the end - no need to modify\n" if $verbose;
	return $transcript;
    }
    
    ############################################################
    # now look at the next codon
    
    ############################################################
    # first the simplest case
    #print STDERR "next codon position: ".($end  + 1 )."..".($end + 3 )."\n";
    if ( $end + 3 <= ($end_exon->end - $end_exon->start + 1) ){
	#print STDERR "end+3 = ".($end  + 3 )." <= ? exon-length = ". ($end_exon->end - $end_exon->start + 1)."\n";
	#print STDERR "looking at the next codon in end exon:\n";
	my $next_codon = $bioseq->subseq( $end+1, $end+3 );      
	if ( uc($next_codon) eq 'TAA' || uc($next_codon) eq 'TAG' || uc($next_codon) eq 'TGA'){ 
	    print STDERR "simple-case: next codon is a stop - extending translation\n" if $verbose;
	    #print STDERR "Before:\n";
	    #$self->_print_Translation( $transcript );
	    $transcript->translation->end( $end + 3 );
	    #print STDERR "After:\n";
	    #$self->_print_Translation( $transcript );
	    $transcript->recalculate_coordinates;
	    return $transcript;
      }
	else{
	print STDERR "next codon is not a stop - not modifying translation\n" if $verbose;
	return $transcript;
      }
    }

    ############################################################
    # more complex cases we need to know if there is a next exon:
    my $next_exon = $self->get_next_Exon( $transcript, $end_exon );
    
    if ( $next_exon ){
      ############################################################
      # homany bases of the next codon sit in $end_exon?
      my $donor_bases_count    = ( $end_exon->end - $end_exon->start + 1 ) - $end;
      my $acceptor_bases_count = 3 - $donor_bases_count;
      
      ############################################################
      # get the next codon
      my $next_bioseq = $next_exon->seq;
      my $donor;
      if ( $donor_bases_count == 0 ){
	$donor = '';
      }
      else{
	$donor    = $bioseq->subseq( $end+1, ( $end_exon->end - $end_exon->start + 1 ));
      }
      my $acceptor = $next_bioseq->subseq( 1, $acceptor_bases_count );
      
      my $next_codon = $donor.$acceptor;
      if ( uc($next_codon) eq 'TAA' || uc($next_codon) eq 'TAG' || uc($next_codon) eq 'TGA'){ 
	print STDERR "shared-codon: next codon is a stop - extending translation\n" if $verbose;
	
	$transcript->translation->end_Exon( $next_exon );
	$transcript->translation->end( $acceptor_bases_count );
	
	############################################################
	# re-set the phases:
	$end_exon->end_phase($donor_bases_count%3);
	$next_exon->phase( $donor_bases_count%3 );
	$transcript->recalculate_coordinates;
	return $transcript;
      }
      else{
	print STDERR "next codon is not a stop - not modifying translation\n" if $verbose;
	return $transcript;
      }
    }    
    elsif( $end + 3 > ($end_exon->end - $end_exon->start + 1) ){
	# there is no next exon and the next codon would fall off the end of the exon 
	
	# need to get the slice sequence
	my $adaptor =  $end_exon->slice->adaptor;
	if ( $adaptor ){
	    my $donor_bases_count    = ( $end_exon->end - $end_exon->start + 1 ) - $end;
	    my $acceptor_bases_count = 3 - $donor_bases_count;
	    
	    # the sequence from the current end exon is:
	    my $donor;
	    if ( $donor_bases_count == 0 ){
		$donor = '';
	    }
	    else{
		$donor = $bioseq->subseq( $end+1, ( $end_exon->end - $end_exon->start + 1 ));
	    }
	    
	    
	    ############################################################
	    # here we distinguish the strands
	    if ( $end_exon->strand == 1 ){
		my $slice_start = $end_exon->slice->start;
		
		############################################################
		# calculate the next codon start/end in chr coordinates 
		
		#print STDERR "exon_end: ".$end_exon->end."\n";
		my $codon_start = $slice_start + ( $end_exon->start + $end - 1 );
		my $codon_end   = $codon_start + 2;
		
		#print STDERR "codon_start: $codon_start\tcodon_end: $codon_end\n";
		my $codon_slice = $adaptor->fetch_by_region
      ($end_exon->slice->coord_system->name, 
       $end_exon->slice->seq_region_name, $codon_start, $codon_end );
		my $codon = $codon_slice->seq;
		
		############################################################
		if ( uc($codon) eq 'TAA' || uc($codon) eq 'TAG' || uc($codon) eq 'TGA'){ 
		print STDERR "forward-strand:next codon (falling off the exon) is a stop - extending translation\n" if $verbose;
		
		#print STDERR "Before:\n";
		#$self->_print_Transcript( $transcript );
		#$self->_print_Translation( $transcript );
		
		$end_exon->end( $end_exon->end + $acceptor_bases_count );
		$transcript->translation->end( $end + 3 );
		
		############################################################
		# update the exon sequence:	    	    
		my $seq_string = $end_exon->slice->subseq( $end_exon->start, $end_exon->end, $end_exon->strand );
		#my $exon_seq = Bio::Seq->new(
		#			     -DISPLAY_ID => $end_exon->stable_id || $end_exon->dbID,
		#			     -MOLTYPE    => 'dna',
		#			     -SEQ        => $seq_string,
		#			     );
		
		#$end_exon->seq($exon_seq);
		$transcript->translation->end_Exon($end_exon);
		#print STDERR "After:\n";
		#$self->_print_Transcript( $transcript );
		#$self->_print_Translation( $transcript );
		$transcript->recalculate_coordinates;
		return $transcript;
	    }
	    else{
		print STDERR "next codon (falling off the exon) is not a stop - not modifying\n" if $verbose;
		return $transcript;
	    }
	}
	else{
    #print STDERR "Slice = ".$end_exon->slice->name."\n";
	    my $slice_start = $end_exon->slice->start;
	    #print STDERR "Slice start = ".$slice_start."\n";
	    ############################################################
	    # calculate the next codon start/end in chr coordinates 
	    #print STDERR "end_exon: ".$end_exon->start."-".
      #  $end_exon->end." exon strand ".$end_exon->strand."\n";
	    
	    my $codon_end   = $slice_start + $end_exon->end - $end - 1;
	    my $codon_start = $codon_end - 2;
    #print STDERR "codon_start: $codon_start\tcodon_end: $codon_end\n";
    if($codon_start <= 0){
      print STDERR "Can't extend the transcript off the end of a ".
        $end_exon->slice->coord_system->name."\n";
      return $transcript;
    }
	    my $codon_slice = $adaptor->fetch_by_region
      ($end_exon->slice->coord_system->name, 
       $end_exon->slice->seq_region_name, $codon_start, $codon_end );
	    my $pre_codon = $codon_slice->seq;
	    
	    #print STDERR "sequence: $pre_codon\n";
	    
	    # need to reverse and complement:
	    my $codon;
	    ( $codon = reverse $pre_codon ) =~tr/gatcGATC/ctagCTAG/; 
	    #print STDERR "revcomp sequence: $codon\n";
	    if ( uc($codon) eq 'TAA' || uc($codon) eq 'TAG' || uc($codon) eq 'TGA'){ 
		print STDERR "reverse-strand: next codon (falling off the exon) is a stop - extending translation\n" if $verbose;
		#print STDERR "extending end_exon from start = ".$end_exon->start." to ".
    #(  $end_exon->start - $acceptor_bases_count )."\n";
		$end_exon->start( $end_exon->start - $acceptor_bases_count);
		$transcript->translation->end( $end + 3 );
		
		#print STDERR "end_exon length: ".($end_exon->end - $end_exon->start + 1 ).
		    " translation end".$transcript->translation->end."\n";
		############################################################
		# update the exon sequence:	    	    
		my $seq_string = $end_exon->slice->subseq( $end_exon->start, $end_exon->end, $end_exon->strand );
		#my $exon_seq = Bio::Seq->new(
		#			     -DISPLAY_ID => $end_exon->stable_id || $end_exon->dbID,
		#			     -MOLTYPE    => 'dna',
		#			     -SEQ        => $seq_string,
		#			     );
		
		#$end_exon->seq($exon_seq);
		$transcript->translation->end_Exon( $end_exon );
		$transcript->recalculate_coordinates;
		return $transcript;
	  }
	  else{
	    print STDERR "next codon (falling off the exon) is not a stop - not modifying\n" if $verbose;
	    return $transcript;
	  }
	}
      }
      else{
	print STDERR "cannot get an adaptor to get the sequence - not modifying the translation\n" if $verbose;
	return $transcript;
      }
    }
    else{
      print STDERR "There is no downstream exon - and no stop codon beyond the last exon - not modifying\n" if $verbose;
      return $transcript;
    }
    
  }
  else{
    print STDERR "transcript has no translation - not modifying anything\n" if $verbose;
    return $transcript;
  }
  
}


############################################################
# method for putting the start codon at the beginning of the translation
# if it is not already there. If the codon prior to the first one is not a stop codon
# we leave it untouched.
# Does not take into account exons that are shared between transcripts - calling code must deal with that.
# The code only works properly if transcript is in genomic coordinates. Reject if it isn't.
sub set_start_codon{
  my ( $self, $transcript ) = @_;

  my  $verbose = 0;

  # check transcript has a translation
  if((!defined $transcript->translation) || (!defined $transcript->translation->start_Exon)){
    print STDERR "Transcript has no translation, or no start exon - maybe a pseudogene?\n";
    return $transcript;
  }

  # check not in RawContig coords
  if ($transcript->translation->start_Exon->slice->adaptor->isa("Bio::EnsEMBL::DBSQL::RawContigAdaptor")){
    print STDERR "transcript must be in genomic coordinates, not RawContig coordinates - skipping\n";
    return $transcript;
  }

  unless ( $transcript->translation ){
    print STDERR "transcript has no translation - cannot put the starts" if $verbose;
    return $transcript;
  }

  # always a good plan


  # useful info in genomic coordinates
  my $strand = @{$transcript->get_all_Exons}[0]->strand;
  my $translation       = $transcript->translation;
  my $start_exon        = $translation->start_Exon;
  my $cdna_coding_start = $transcript->cdna_coding_start;
  my $cdna_seq          = uc($transcript->spliced_seq);
  my @pepgencoords      = $transcript->pep2genomic(1,1);
  if(scalar(@pepgencoords) > 2) {
    print STDERR "peptide start does not map cleanly - not modifying transcript\n";
    return $transcript;
  }
  
  my $pepgenstart = $pepgencoords[0]->start;
  my $pepgenend   = $pepgencoords[$#pepgencoords]->end;

  unless($pepgencoords[0]->isa('Bio::EnsEMBL::Mapper::Coordinate') && 
	 $pepgencoords[$#pepgencoords]->isa('Bio::EnsEMBL::Mapper::Coordinate')) {
          print STDERR "peptide coordinate(s)  maps to gap - not modifying transcript\n";
	  return $transcript;
        }

  #print "Peptide genomic location = " . $pepgenstart . " " . $pepgenend . "\n";

  ############################################################
  # first see whether the transcript already begins with ATG
  my $first_codon = substr($cdna_seq, $cdna_coding_start-1, 3);

  #print STDERR "first codon: $first_codon\n";

  if ( uc($first_codon) eq 'ATG' ){
    print STDERR "transcript already starts with ATG - no need to modify\n" if $verbose;
    return $transcript;
  }
  
  ############################################################
  # now look at the previous codon
  ############################################################
  # first the simplest cases
  if($cdna_coding_start>3){
    # the previous codon is in the cdna
    $first_codon = substr($cdna_seq, $cdna_coding_start-4, 3);
    if ($first_codon ne 'ATG'){
      print STDERR "Upstream codon is not an ATG - not modifying transcript\n";
      return $transcript;
    }
    else{
      if($verbose){
	print STDERR "upstream codon is an ATG\n";
	print STDERR "Before: \n";
	Bio::EnsEMBL::Pipeline::Tools::TranscriptUtils->_print_Translation($transcript);
      }

      # save current coords, just in case we need to revert
      my $current_translation_start = $transcript->translation->start;
      my $current_start_exon        = $transcript->translation->start_Exon;
      my $current_start_exon_start  = $current_start_exon->start;
      my $current_start_exon_end  = $current_start_exon->end;
      my $current_start_exon_phase = $current_start_exon->phase;
      my $newstartexon;
      my $current_newstartexon_endphase;

      my @coords = $transcript->cdna2genomic($cdna_coding_start-3,$cdna_coding_start-1,$strand);
      my $new_start;
      my $new_end;

      # check not mapping to gaps
      unless($coords[0]->isa('Bio::EnsEMBL::Mapper::Coordinate') &&
	     $coords[$#coords]->isa('Bio::EnsEMBL::Mapper::Coordinate')) {
	print STDERR "new coordinate(s) maps to gap - not modifying transcript\n";
	return $transcript;
      }

      if (scalar(@coords) > 2){
	print STDERR "coordinate mapping not done cleanly - not modifying transcript!\n";
	return $transcript;
      }
      elsif(scalar(@coords) == 2){
	print STDERR "new start codon split across intron\n";
	if ($verbose){
	  print "coord[0] = " . $coords[0]->start . " " . $coords[0]->end ."\n";
	  print "coord[1] = " . $coords[1]->start . " " . $coords[1]->end ."\n";
	}
	
	if($strand == 1){
	  $new_start = $coords[0]->start;
	  $new_end   = $coords[$#coords]->end;}
	else{
	  $new_start = $coords[0]->end;
	  $new_end   = $coords[$#coords]->start; 
	}
	
	# find exon
	my $newstartexon = $self->get_previous_Exon($transcript, $start_exon);

	if (!defined($newstartexon)) {
	  print STDERR "Failed finding new start exon - not modifying transcript\n";
	  return $transcript;
	}

	# save in case we need to revert
	my $current_newstartexon_endphase = $newstartexon->end_phase;
	
	my $newphase;
	if ($strand == 1) {
	  $newphase = $newstartexon->end - $new_start + 1;
	} else {
	  $newphase = $new_start - $newstartexon->start + 1;
	}
	
	print "New Phase = $newphase\n";
	
	$start_exon->phase($newphase);
	$newstartexon->end_phase($newphase);
  
	$translation->start_Exon($newstartexon);
	$translation->start($newstartexon->length-$newphase+1);

	# make sure it still translates, and revert if necessary
	eval{
	  $transcript->translate;
	};
	if($@){
	  print STDERR "problem with modified transcript - reverting coordinates\n";
	  $transcript->start_Exon($current_start_exon);
	  $transcript->start_Exon->start($current_start_exon_start);
	  $transcript->start_Exon->end($current_start_exon_end);
	  $translation->start($current_translation_start);
	  $transcript->start_Exon->phase($current_start_exon_phase);
	  if (defined $newstartexon){
	    $newstartexon->end_phase($current_newstartexon_endphase);
	  }
	}	
	
	if($verbose){
	  print "Translation seq AFTER:\n";
	  Bio::EnsEMBL::Pipeline::Tools::TranscriptUtils->_print_Translation($transcript);
	}
	$transcript->recalculate_coordinates;
	return $transcript;
      }
      else{
	print STDERR "New start codon doesn't split across introns - but which exon is it in?\n";
	$new_start = $coords[0]->start;
	$new_end   = $coords[0]->end;

	if (($strand == 1  && $new_end == $pepgenstart-1) ||
	    ($strand == -1 && $new_start == $pepgenend+1)) {
	  print "In current start exon\n";
	  
	  $translation->start($translation->start-3);
	  
	} 
	else{
	  print STDERR "In previous exon\n";

	  # find exon
	  my $newstartexon = $self->get_previous_Exon($transcript, $start_exon);
	  if (!defined($newstartexon)) {
	    print STDERR "Failed finding new start exon - how can this be?\n";
	    return $transcript;
	  }

	  $current_newstartexon_endphase = $newstartexon->end_phase;
           
	  # make the boundary phases 0 - the ATG is the last codon of $newstartexon 
	  # as we know it doesn't cross the intron
	  $start_exon->phase(0);
	  $newstartexon->end_phase(0);

	  # Reset translation start exon
	  $translation->start_Exon($newstartexon);
	  $translation->start($newstartexon->length-2);
	}
	
	# make sure it still translates, and revert if necessary
	eval{
	  $transcript->translate;
	};

	if($@){
	  print STDERR "problem with modified transcript - reverting coordinates\n";
	  $transcript->start_Exon($current_start_exon);
	  $transcript->start_Exon->start($current_start_exon_start);
	  $transcript->start_Exon->end($current_start_exon_end);
	  $translation->start($current_translation_start);
	  $transcript->start_Exon->phase($current_start_exon_phase);
	  $newstartexon->end_phase($current_newstartexon_endphase);
	}

	if($verbose){
	  print "Translation seq AFTER:\n";
	  Bio::EnsEMBL::Pipeline::Tools::TranscriptUtils->_print_Translation($transcript);
	}
	$transcript->recalculate_coordinates;
	return $transcript;
      } 
      
    }
  }

  ############################################################
  # more complex cases: the previous codon falls off the cdna
  else{
    my $codon_start;
    my $codon_end; 
    
    if ($strand == 1) {
      $codon_start = $pepgenstart - 3;
      $codon_end   = $pepgenstart - 1;
    } else {
      $codon_start = $pepgenend + 1;
      $codon_end   = $pepgenend + 3;
    }
    
    my $seq_adaptor = $start_exon->slice->adaptor->db->get_SequenceAdaptor;
    my $codonseq      = uc(${$seq_adaptor->fetch_by_Slice_start_end_strand
                           ($start_exon->slice, $codon_start,$codon_end, 
                            $strand)});
    
    #print "Got codon seq " . $codonseq . "\n";
    if ($codonseq ne "ATG") {
      #print STDERR "upstream codon (faling off the slice) is not ATG - not modifying transcript\n";
      return $transcript;
    }
    else{
      # fun fun fun
      if($verbose){
	print STDERR "Before:\n";
	Bio::EnsEMBL::Pipeline::Tools::TranscriptUtils->_print_Translation($transcript);
      }

      # save current coordinates in case we need to revert
      my $current_start_exon         = $start_exon;
      my $current_start_exon_start    = $start_exon->start;
      my $current_start_exon_end      = $start_exon->end;
      my $current_start_exon_phase    = $start_exon->phase;
      my $current_start_exon_endphase = $start_exon->end_phase;
      my $current_translation_start  = $translation->start;
      my $current_translation_end    = $translation->end;

      if($strand == 1){
	$start_exon->start($codon_start)
      }
      else{
	$start_exon->end($codon_end)
      }
      $start_exon->phase(0);
      if ($translation->end_Exon == $start_exon){
	$translation->end($translation->end + (4-$translation->start));
      }
      $translation->start(1);

      # make sure it still translates, and revert if necessary
      eval{
	$transcript->translate;
      };
      if($@){
	print STDERR "problem with modified transcript - reverting coordinates\n";
	$transcript->start_Exon($current_start_exon);
	$transcript->start_Exon->start($current_start_exon_start);
	$transcript->start_Exon->end($current_start_exon_end);
	$translation->start($current_translation_start);
	$translation->end($current_translation_end);
	$transcript->start_Exon->phase($current_start_exon_phase);
	$transcript->start_Exon->end_phase($current_start_exon_endphase);
      }

	if($verbose){
	  print "Translation seq AFTER:\n";
	  Bio::EnsEMBL::Pipeline::Tools::TranscriptUtils->_print_Translation($transcript);
	}
      $transcript->recalculate_coordinates;
	return $transcript;
    }
  }
}

############################################################
# method to retrieve the downstream exon of $exon, which must be part of transcript

sub get_next_Exon{
  my ($self, $transcript, $exon ) = @_;
    
  # this order the exons 5' to 3'

  my @exons = @{$transcript->get_all_Exons};
  for (my $i=0; $i<=$#exons; $i++ ){
    if ( $exons[$i]->start == $exon->start 
	 && 
	 $exons[$i]->end   == $exon->end
	 &&
	 $exons[$i]->strand == $exon->strand 
	 &&
	 ($i+1) <= $#exons
       ){
      return $exons[$i+1];
    }
  }
  return undef;
}
  

############################################################

sub get_previous_Exon{
  my ($self, $transcript, $exon ) = @_;
    
  # this order the exons 5' to 3'
  
  my @exons = @{$transcript->get_all_Exons};
  
  for (my $i=0; $i<=$#exons; $i++ ){
    if ( $exons[$i]->start == $exon->start 
	 && 
	 $exons[$i]->end   == $exon->end
	 &&
	 $exons[$i]->strand == $exon->strand 
	 &&
	 $i > 0 
       ){
      return $exons[$i-1];
    }
  }
  return undef;
}

############################################################


  

sub _get_ORF_coverage {

  my ($self, $transcript) = @_;
  my $orf_coverage;
  my $transcript_length = $transcript->length;
#print STDERR "transcript length: $transcript_length\n";


  my $translateable = $transcript->translateable_seq;
  my $translateable_length = length($translateable);
#print STDERR "translateable length: $translateable_length\n";
  $orf_coverage = 100 * ($translateable_length/$transcript_length);
  print STDERR "orf coverage: $orf_coverage\n";
  return $orf_coverage;

}


sub feature_info{
  my ($name, $feature) = @_;

  return $name." ".$feature->start." ".$feature->end." ".$feature->strand."\n";
}


1;
