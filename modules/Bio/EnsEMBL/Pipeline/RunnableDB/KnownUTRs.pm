#
# Ensembl module for Bio::EnsEMBL::Pipeline::RunnableDB::TargettedE2G.pm
#
# Cared for by EnsEMBL  <ensembl-dev@ebi.ac.uk>
#
# Copyright GRL and EBI
#
# You may distribute this module under the same terms as perl itself

# POD documentation - main docs before the code

=head1 NAME

Bio::EnsEMBL::Pipeline::RunnableDB::KnownUTRs

=head1 SYNOPSIS

my $t_e2g = new Bio::EnsEMBL::Pipeline::RunnableDB::KnownUTRs(
                                                                    );

$t_e2g->fetch_input();
$t_e2g->run();
$t_e2g->output();
$t_e2g->write_output(); #writes to DB

=head1 DESCRIPTION

Mostly for Refseqs, but can use specified cDNA sequences to add UTRs to genewise genes.
Uses Refseq NMs to add UTRs to targetted genes built with NPs.

Runs on genomic slices.

=head1 CONTACT

Ensembl - ensembl-dev@ebi.ac.uk

=head1 APPENDIX

The rest of the documentation details each of the object methods. Internal methods are usually preceded with a _

=cut


# Let the code begin...


package Bio::EnsEMBL::Pipeline::RunnableDB::KnownUTRs;

use vars qw(@ISA);
use strict;
use Storable qw(dclone);

use Bio::EnsEMBL::KillList::KillList;
use Bio::EnsEMBL::KillList::DBSQL::DBAdaptor;

use Bio::EnsEMBL::Utils::Exception qw(throw warning);
use Bio::EnsEMBL::Utils::Argument qw( rearrange );
use Bio::EnsEMBL::Gene;
use Bio::EnsEMBL::Exon;
use Bio::EnsEMBL::Transcript;
use Bio::EnsEMBL::Translation;
use Bio::EnsEMBL::Pipeline::RunnableDB;
use Bio::SeqIO;
use Bio::EnsEMBL::Analysis::Runnable::ExonerateTranscript;
use Bio::EnsEMBL::Pipeline::Tools::ExonUtils;
use Bio::EnsEMBL::Pipeline::Tools::TranscriptUtils;
use Bio::EnsEMBL::Pipeline::Runnable::MiniGenomewise;

use Bio::EnsEMBL::Pipeline::Config::GeneBuild::Databases qw (
							     GB_DBNAME
							     GB_DBHOST
							     GB_DBUSER
							     GB_DBPASS
							     GB_DBPORT
							     GB_GW_DBNAME
							     GB_GW_DBHOST
							     GB_GW_DBUSER
							     GB_GW_DBPASS
							     GB_GW_DBPORT
							     GB_COMB_DBNAME
							     GB_COMB_DBHOST
							     GB_COMB_DBUSER
							     GB_COMB_DBPASS
							     GB_COMB_DBPORT
							    );

use Bio::EnsEMBL::Pipeline::Config::GeneBuild::Sequences qw (
							     GB_PROTEIN_INDEX
							     GB_PROTEIN_SEQFETCHER
							     GB_CDNA_INDEX
							     GB_CDNA_SEQFETCHER
							    );

use Bio::EnsEMBL::Pipeline::Config::GeneBuild::General   qw (
							     GB_INPUTID_REGEX
							    );

use Bio::EnsEMBL::Pipeline::Config::GeneBuild::Scripts   qw (
							     GB_FPCDIR
							    );

use Bio::EnsEMBL::Pipeline::Config::GeneBuild::Targetted qw (
							     GB_TARGETTED_GW_GENETYPE
);

@ISA = qw(Bio::EnsEMBL::Pipeline::RunnableDB);

sub new {
  my ($class,@args) = @_;
  my $self = $class->SUPER::new(@args);
    my $seqfetcher = $self->make_seqfetcher($GB_PROTEIN_INDEX, $GB_PROTEIN_SEQFETCHER);
  return $self;
}

=head2 make_seqfetcher

 Title   : make_seqfetcher
 Usage   :
 Function: get/set
 Example :
 Returns : Bio::DB::RandomAccessI
 Args    :


=cut

sub make_seqfetcher{
  my ( $self, $index, $seqfetcher_class  ) = @_;
  my $seqfetcher;

  (my $class = $seqfetcher_class) =~ s/::/\//g;
  require "$class.pm";

  print "index = $index \n";

  if(defined $index && $index ne ''){
    my @db = ( $index );

    # make sure that your class is compatible with the index type
    $seqfetcher = "$seqfetcher_class"->new('-db' => \@db, );
  }
  else{
    throw("can't make seqfetcher\n");
  }

  return $seqfetcher;

}

=head2 fetch_input

 Title   : fetch_input
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub fetch_input{
  my ($self,@args) = @_;

  $self->make_runnables;
}

sub make_runnables{
  my ($self) = @_;
  my %kill_list = %{$self->populate_kill_list};

  # set up array that will contain the whole set of cdna sequences to be aligned using exonerate.
  my @cdna_sequences; 

  # set up seqfetchers
  my $protein_fetcher = $self->make_seqfetcher($GB_PROTEIN_INDEX, $GB_PROTEIN_SEQFETCHER);
  my $cdna_fetcher = $self->make_seqfetcher($GB_CDNA_INDEX, $GB_CDNA_SEQFETCHER);

  $self->fetch_sequence([], $self->genewise_db);

  my $pipeline_db = $self->db;

  # for checking cdna_ids
  my $pmfa = $pipeline_db->get_PmatchFeatureAdaptor();

  # get all targetted genes in the given slice, from which the evidence for 
  # these genes can be derived.
  my $genes  = $self->query->get_all_Genes_by_type($GB_TARGETTED_GW_GENETYPE);  
  my $ftg    = $self->query->get_all_Genes_by_type('FullTargettedGenewise');
  my $te     = $self->query->get_all_Genes_by_type('TargettedExonerate');
  my $xtg    = $self->query->get_all_Genes_by_type('XrateTargettedGenewise');

  push(@$genes, @$ftg);
  push(@$genes, @$te);
  push(@$genes, @$xtg);

 GENE:
  foreach my $gene(@$genes){
    my $protein_id;
  EXON:
    foreach my $exon(@{$gene->get_all_Exons}){
      my @feat = @{$exon->get_all_supporting_features};
      foreach my $feat(@feat){
	$protein_id = $feat->hseqname;
	last EXON if (defined $protein_id);
      }
    }
    
    # Using the protein id of the targetted gene, determine the
    # corresponding cDNA id.
    
  #  print STDERR "Gene " . $gene->dbID . " built from $protein_id\n";
    
    my $cdna_id = $pmfa->get_cdna_id($protein_id);
    
    if (!defined $cdna_id || $cdna_id eq ''){
      #print STDERR "no matching cdna id for $protein_id\n";
      next GENE;
    }
    if(defined $kill_list{$cdna_id}){
      print STDERR "skipping " . $cdna_id . " present in kill list\n";
      next GENE;
    }
       
    # get cdna sequence
    my $cdna;
    eval{
      $cdna = $cdna_fetcher->get_Seq_by_acc($cdna_id);
    };
    
    if($@) {
      throw("problem fetching cdna sequence for [$cdna_id], will not be able to build UTR\n[$@]\n");
    }

    
    # If the cdna cant be retrieved try decrementing the version number 
    # and having a second attempt.
    
    unless ($cdna) {
      
      warning("Unable to fetch cDNA sequence [$cdna_id].  Will decrement\n" .
              "the cDNA version number and have another go.");
      
      if ($cdna_id =~ s/([\_\w]+)\.(\d+)/$1/){
	my $version_number = $2;
	$version_number--;
	$cdna_id = $1 . '.' . $version_number;
      }
      eval{
	$cdna = $cdna_fetcher->get_Seq_by_acc($cdna_id);
      };
      
      if($@) {
	throw("problem fetching cdna sequence for [$cdna_id], will not be able to build UTR\n[$@]\n");
      }
    }

    # Pair the cDNA id with the corresponding gene
    # and and cDNA sequence to be used with exonerate
    if ($cdna) {
    #  print "cDNA: ", $cdna_id, " fetched correctly,now pairing with corresponding protein id\n";
      $self->targetted_cdna_pairs($gene, $cdna_id);
      push (@cdna_sequences, $cdna);
    } else {
      warning("Unable to fetch cDNA sequence [$cdna_id] even after incrementing the version number.");
    }  
  }
  
  print "YOU HAVE ",scalar(@cdna_sequences)," BEFORE CHUNKING\n";
  
  
  my %cdna_seq_chunks = %{$self->make_cdna_chunks(\@cdna_sequences)};
  
#####
# Here I would like to close the gene loop and create the cDNA chunks.
# Once I have the chunks I will run the exonerate and store each alignment in a hash
  
  my @genomic_seqs = ($self->query->get_repeatmasked_seq(['RepeatMask'],1));

  foreach my $cdna_chunk (keys %cdna_seq_chunks){

    my @cdna_seqs = @{$cdna_seq_chunks{$cdna_chunk}};

    # make ExonerateTranscript
    my $r = Bio::EnsEMBL::Analysis::Runnable::ExonerateTranscript->new(
                                                                       -analysis => $self->analysis,
                                                                       -target_seqs => \@genomic_seqs,
                                                                       -query_type => 'dna',
                                                                       -query_seqs => \@cdna_seqs,
                                                                       -program      => '/software/ensembl/bin/exonerate-1.4.0',
                                                                       -options      => '--model est2genome --softmasktarget TRUE --gappedextension FALSE --score 200 --bestn 1 --saturatethreshold 10',
                                                                       );
    
    $self->runnables($r);
  } 
}



=head2 run

 Title   : run
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub run {
  my ($self,@args) = @_;

  my $targetted_tsf;
  my $exonerate_tsf;

 RUNNABLE:
  foreach my $runnable($self->runnables){
    
    my @cdna_seq = @{$runnable->query_seqs};
    
    $runnable->run;
    
    # make gene(s) from exonerate output
    my @exonerate_transcripts = @{$runnable->output};
    
    next RUNNABLE unless scalar(@exonerate_transcripts);
    
    print STDERR "got " . scalar(@exonerate_transcripts) . " transcripts from exonerate\n";
    
  RUNNABLE_CDNA:
    foreach my $exonerate_transcript (@exonerate_transcripts){
      
      #print "Your exonerate transcript id: ", $exonerate_transcript->get_all_supporting_features->[0]->hseqname,"\n";
      my $cdna_id = $exonerate_transcript->get_all_supporting_features->[0]->hseqname;
            
      # which targetted gene do we need to add UTRs to?
      my @targetted_genes = @{$self->get_targetted_gene_from_cdna($cdna_id)};
      
      print STDERR "For the cdna ",$cdna_id , " there are ",scalar(@targetted_genes) ," genes\n"; 

      foreach my $targetted_gene (@targetted_genes){
        # combine blat & targetted genes
        my $combined_transcript = $self->combine_transcripts($targetted_gene->get_all_Transcripts->[0], $exonerate_transcript);
        
        if ( $combined_transcript ){
          
	  my @csf_array;
	  foreach my $sf(@{$targetted_gene->get_all_Transcripts->[0]->get_all_supporting_features}){
	    $sf->slice($combined_transcript->slice);
	    push @csf_array, $sf;
	  } 
	  
	  my @esf_array;
	  foreach my $sf(@{$exonerate_transcript->get_all_supporting_features}){
	    $sf->slice($combined_transcript->slice);
	    push @esf_array, $sf;
	  }   
	  
	  $combined_transcript = $self->_transfer_evidence($combined_transcript, $exonerate_transcript);
	  $combined_transcript->add_supporting_features(@csf_array);
          $combined_transcript->add_supporting_features(@esf_array);
          $self->make_gene($combined_transcript);
        }
        else{
          print STDERR "no combined gene built from " . $targetted_gene->dbID ."\n";
          next RUNNABLE_CDNA;
        }
      }



    }
  }
  # remap to raw contig coords
  my @remapped = $self->remap_genes();
  
  $self->output(@remapped);

  #print "I REACH REMAPPED STATUS\n";
  
  foreach my $outgene ($self->output){
    
    foreach my $newtrans (@{$outgene->get_all_Transcripts}){
        #print "ADDING analysis to NEW TRANSCRIPT\n";
        $newtrans->analysis($self->analysis);
        #$newtrans->add_supporting_features(@features);
        foreach my $ntsf (@{ $newtrans->get_all_supporting_features }){
         #   print "NEW TRANSCRIPT SUPPORTING FEATURE: ", $ntsf->hseqname,"\n";
          $ntsf->analysis($self->analysis);
        }
        foreach my $ntexon (@{$newtrans->get_all_Exons}){
          #print "ADDING ANALYSIS TO NEW EXON: ",$self->analysis->logic_name, "\n";
          $ntexon->analysis($self->analysis);
          foreach my $newexonsf(@{$ntexon->get_all_supporting_features()}){
            $newexonsf->analysis($self->analysis);
          }
        }
      }
      
 
    print "Gene was Remapped\n";
    eval {
      foreach my $outtrans (@{$outgene->get_all_Transcripts}){
        print "There is a transcript for this remapped gene\n";
        print "And the remapped transcript has ",scalar(@{$outtrans->get_all_Exons})," exons\n";
      }
    };
    if ($@){
      print "This remapped gene don't have transcripts\n";
    }

  }
  
}

=head2 output

 Title   : output
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub output{
   my ($self, @genes) = @_;
  if (!defined($self->{'_output'})) {
      $self->{'_output'} = [];
  }

   if(@genes){
     push(@{$self->{'_output'}},@genes);
   }

   return @{$self->{'_output'}};
}


=head2 runnables

 Title   : runnables
 Usage   : $obj->runnables($newval)
 Function: get/set for BlatToGenes runnables
 Returns : value of runnables
 Args    : Bio::EnsEMBL::Pipeline::RunnableI


=cut

sub runnables{
  my ($self, $runnable) = @_;

  if (!defined($self->{'_runnables'})) {
    $self->{'_runnables'} = [];
  }
  
  if (defined($runnable) ){
    push( @{$self->{'_runnables'}}, $runnable);
  }
  
  return @{$self->{'_runnables'}};
}

=head2 write_output
    
    Title   :   write_output
    Usage   :   $self->write_output
    Function:   Writes output data to db
    Returns :   none
    Args    :   none
    
=cut
    
    
sub write_output {
  my($self) = @_;
  
  my $output_db = new Bio::EnsEMBL::DBSQL::DBAdaptor(
                                                     '-host'   => $GB_COMB_DBHOST,
                                                     '-user'   => $GB_COMB_DBUSER,
                                                     '-pass'   => $GB_COMB_DBPASS,
                                                     '-port'   => $GB_COMB_DBPORT,
                                                     '-dbname' => $GB_COMB_DBNAME,
                                                     );
  my $gene_adaptor = $output_db->get_GeneAdaptor;
  
  GENE: foreach my $gene ($self->output) {

    # do a per gene eval...
    eval {
      $gene_adaptor->store($gene);
      print STDERR "wrote to database gene dbID " . $gene->dbID . "coords ".$gene->start()."-".$gene->end()."\n";
    }; 
    if( $@ ) {
      print STDERR "UNABLE TO WRITE GENE\n\n$@\n\nSkipping this gene\n";
    }
  }
}


=head2 make_cdna_chunks

    Title   :   make_cdna_cnuks
    Usage   :   $self->make_cdna_chunks
    Function:   Get all the cDNAs ids selected to align and make chunks containing 100 cDNAs each
    Returns :   hash of cdna sequences grouped in chunks of 100
    Args    :   Array of Bio::EnsEMBL::Gene

=cut

sub make_cdna_chunks{
  my ($self, $cdna_seqs) = @_;
  
  my $number_of_seqs = scalar(@{$cdna_seqs});
  my $files_in_chunk = 0;
  my $number_of_chunk = 0;
  my %chunks;
  
  while(@{$cdna_seqs}){
    if ($files_in_chunk<10){
      #unless ($chunks{$number_of_chunk}){
      #  $chunks{$number_of_chunk};
      #}
      
      push(@{$chunks{$number_of_chunk}}, pop(@{$cdna_seqs}));
      $files_in_chunk++;
      
    }else{
      push(@{$chunks{$number_of_chunk}}, pop(@{$cdna_seqs}));
      $number_of_chunk++;
      $files_in_chunk =0;
    }
    
  }
  print "YOU HAVE ", $number_of_chunk+1," CHUNKS\n";
  return \%chunks;  
  
}

=head2 targetted_cdna_pairs

    Title   :   targetted_cdna_pairs
    Usage   :   $self->targetted_cdna_pairs($gene, $cdna)
    Function:   Pairs targetted gene objects with the accession of the cdna that it will use for UTRs
    Returns :   nothing
    Args    :   Bio::EnsEMBL::Gene, string

=cut

sub targetted_cdna_pairs {
  my ($self, $gene, $cdna) = @_;
  unless (defined $gene && defined $cdna){
    throw("Missing arguments to targetted_cdna_pairs: [$gene], [$cdna]\n");
  }

  unless ($gene->isa("Bio::EnsEMBL::Gene")){
    throw("$gene is not a Bio:EnsEMBL::Gene\n");
  }
 # print "PROTEIN ",$gene->dbID," AND CDNA ",$cdna," HAVE BEEN PAIRED\n";
 
  push(@{$self->{_targetted_cdnas}{$cdna}}, $gene);
}

=head2 get_targetted_gene_from_cdna

    Title   :   get_targetted_gene_from_cdna
    Usage   :   $self->get_targetted_gene_from_cdna($cdna_id)
    Function:   Retrieves targetted gene that needs to have UTRs from cdna_id; 
                currently throws if more than one gene shares the same cdna id
    Returns :   Bio::EnsEMBL::Gene
    Args    :   string

=cut

sub get_targetted_gene_from_cdna{
  my ($self, $cdna) = @_;
  my $genes;

 ENTRY:
  foreach my $entry(keys %{$self->{_targetted_cdnas}}){
    if ($entry eq $cdna){
      if (defined $genes){
	throw("More than one gene for $cdna - skip for now\n");
      }
      $genes = $self->{_targetted_cdnas}{$entry};
      foreach my $gene(@{$genes}){ 
    
        # losing the db in the hashing for some reason ...
        $gene->adaptor->db($self->genewise_db);
      }
    }
  }

  throw("Unable to find Targetted Gene from cDNA") 
    unless $genes;

  return $genes;
}

sub combine_transcripts{
  my ($self, $genewise_transcript, $cdna_transcript) = @_;

  my $cdna_start;
  my $cdna_end;

  $cdna_transcript->slice($genewise_transcript->slice);

  foreach my $cdna_sf(@{$cdna_transcript->get_all_supporting_features}){

    $cdna_sf->slice($genewise_transcript->slice);
    $cdna_start = $cdna_sf->start;
    $cdna_end = $cdna_sf->end;

  }

  #print "my cdna transcript has ",scalar(@{$cdna_transcript->get_all_Exons})," exons\n";
  my @cdna_transcript_exons = @{$cdna_transcript->get_all_Exons};
  foreach my $cdna_exon(@cdna_transcript_exons){

    $cdna_exon->slice($genewise_transcript->slice);

    foreach my $e_cdna_sf(@{$cdna_exon->get_all_supporting_features}){

      #print "my cdna exons have supporting features\n";
      $e_cdna_sf->slice($genewise_transcript->slice);
    }

  }

  my $gw_start = $genewise_transcript->coding_region_start;
  my $gw_end   = $genewise_transcript->coding_region_end;

  print "COORDINATES: cdnaS ",$cdna_start," cdnaE ",$cdna_end," gwS ",$gw_start," gwE ",$gw_end,"\n";

  if ($cdna_start<$gw_end && $cdna_end>$gw_start){

    print "Genewise gene and cDNA exonerate transcript overlap\n";
        
    # transfer gene coordinates to entire chromosome to prevent problems arising
    # due to offset with repeat features 
    my $ref_db = new Bio::EnsEMBL::DBSQL::DBAdaptor
        (
         '-host'   => $GB_DBHOST,
         '-user'   => $GB_DBUSER,
         '-dbname' => $GB_DBNAME,
         '-pass'   => $GB_DBPASS,
         '-port'   => $GB_DBPORT,
         );
    #store reference db internally
    
    my $rsa = $ref_db->get_SliceAdaptor;
    
    my $chromosome_slice = $rsa->fetch_by_region(
						 'toplevel',
						 $self->query->chr_name,
                                                 );
    
    # IF YOU WANT TO RUN THE SCRIPT ON SLICES INSTEAD OF CHROMOSOMES
    # YOU MAY NEED TO UNCOMMENT THE FOLLOWING CODE

    
    my  $tmp =$genewise_transcript->transfer($chromosome_slice); 
    $genewise_transcript=$tmp;
    print "Genewise Transcript ",$genewise_transcript->slice->name,"\n";

    my $cdna_tmp =  $cdna_transcript->transfer($chromosome_slice); 
    $cdna_transcript =$cdna_tmp;
    print "Exonerate Transcripts ", $cdna_transcript->slice->name,"\n";
    
    
    my $modified_peptide = 0;
    my @combined_transcripts  = ();
    
    my @gw_exons = @{$genewise_transcript->get_all_Exons}; # ordered array of exons
    my @cdna_exons  = @{$cdna_transcript->get_all_Exons}; # ordered array of exons
    
    # OK, let's see if we need a new gene
    # base it on the existing genewise one
    my $newtranscript = new Bio::EnsEMBL::Transcript;
    my $coding_overlap = 0;

    foreach my $exon(@gw_exons){
      
      $newtranscript->add_Exon($exon);

      #sneak in the check, if some coding region is actually overlapping
      if($exon->start > $gw_start){
			print "EXON START: ",$exon->start,"\n"; 
	    CODINGCHECK: foreach my $cdna_exon (@cdna_exons){
	    print "CDNA EXON START: ",$cdna_exon->start,"\n";
	  if(($exon->strand == $cdna_exon->strand) and ($exon->overlaps($cdna_exon))){
	    $coding_overlap = 1;
	    last CODINGCHECK;
	  }
	}
      }

    }
    if(!$coding_overlap){
      print STDERR "NO CODING REGIONS ARE OVERLAPPING. SKIPPING.\n";
      return undef;
    }
    
    my $translation   = new Bio::EnsEMBL::Translation;
    $translation->start($genewise_transcript->translation->start);
    $translation->end($genewise_transcript->translation->end);
    $translation->start_Exon($genewise_transcript->translation->start_Exon);
    $translation->end_Exon($genewise_transcript->translation->end_Exon);
    
    $newtranscript->translation($translation);
    $newtranscript->translation->start_Exon($newtranscript->start_Exon);
    $newtranscript->translation->end_Exon($newtranscript->end_Exon);
    
    my $eecount = 0;
    my $modified_peptide_flag;
    
  EACH_CDNA_EXON:
    foreach my $ee (@cdna_exons){
      $ee->slice($genewise_transcript->slice);
      
      # check strands are consistent
      if ($ee->strand != $gw_exons[0]->strand){
        warning("gw and e2g exons have different strands - can't combine transcripts\n") ;
        return undef;
      }
      
      # single exon genewise prediction?
      if(scalar(@gw_exons) == 1) {
         #print "I enter single exon gene\n";
        
	($newtranscript,$modified_peptide_flag) = $self->transcript_from_single_exon_genewise( $ee,
											       $gw_exons[0],
											       $newtranscript,
											       $translation,
											       $eecount,
											       @cdna_exons);
      }
      
      else {
         #print "I enter multiexon gene\n";#test
        
	($newtranscript,$modified_peptide_flag) = $self->transcript_from_multi_exon_genewise($ee,
											     $newtranscript,
											     $translation,
											     $eecount,
											     $genewise_transcript,
											     $cdna_transcript)
          }
      
      if ( $modified_peptide_flag ){
        $modified_peptide = 1;
      }
      
      # increment the exon
      $eecount++;
      
    } # end of EACH_CDNA_EXON
    
    
   
    ##############################
    # expand merged exons
    ##############################
    # the new transcript is made from a merged genewise gene
    # check the transcript and expand frameshifts in all but original 3' gw_exon
    # (the sub_SeqFeatures have been flushed for this exon)
    if (defined($newtranscript)){
      #print "I enter new defined transcript\n"; #test
      foreach my $ex (@{$newtranscript->get_all_Exons}){
        if($ex->sub_SeqFeature && scalar($ex->sub_SeqFeature) > 1 ){
          my @sf    = $ex->sub_SeqFeature;
          
          my $first = shift(@sf);
          
          $ex->end( $first->end);
          
          # add back the remaining component exons
          foreach my $s(@sf){
            #print "Supporting feature slice ", $s->slice->name,"\n"; #test
            $newtranscript->add_Exon($s);
            $newtranscript->sort;
          }
          # flush the sub_SeqFeatures
          $ex->flush_sub_SeqFeature;
        }
      }
      
      # check that the result is fine
      #  unless( Bio::EnsEMBL::Pipeline::Tools::TranscriptUtils->_check_Transcript($newtranscript,$self->query) ){
      unless( Bio::EnsEMBL::Pipeline::Tools::TranscriptUtils->_check_Transcript($newtranscript,$chromosome_slice) ){
        
        print STDERR "problems with this combined transcript, return undef\n";
        return undef;
      }
      unless( Bio::EnsEMBL::Pipeline::Tools::TranscriptUtils->_check_Translation($newtranscript) ){
        print STDERR "problems with this combined translation, return undef\n";
        return undef;
      }
      
      print "new transcript looks sane\n"; #test
      
      # check translation is the same as for the genewise gene we built from
      my $foundtrans = 0;
      
      # the genewise translation can be modified due to a disagreement in a
      # splice site with cdnas. This can happen as neither blast nor genewise can
      # always find very tiny exons.
      # we then recalculate the translation:
      
     
      my $newtrans;
      if ( $modified_peptide ){
        my $strand = $newtranscript->start_Exon->strand;
        
        print STDERR "before genomewise:\n";
        $newtrans = $self->_recalculate_translation($newtranscript,$strand); 
        print STDERR "after genomewise:\n";
        # if the genomewise results gets stop codons, return the original transcript:
        unless( Bio::EnsEMBL::Pipeline::Tools::TranscriptUtils->_check_Translation($newtrans) ){
          print STDERR "Arrgh, stop codons, returning the original transcript\n";
          $newtrans = $newtranscript;
        }
      }
      else{
        $newtrans = $newtranscript;
      }
      return $newtrans;
    }
    else{
          warning("No combination could be built\n");
      return undef;
    }
  }else{ 
   # print "Genewise Gene and cDNA exonerate transcript don't overlap, skiping\n";
    warning("Genewise Gene and cDNA exonerate transcript don't overlap, skiping\n");
    return undef;
  }
}


sub transcript_from_single_exon_genewise {
    my ($self, $cdna_exon, $genewise_exon, $transcript, $translation, $exoncount, @cdna_exons) = @_;

    # save out current translation end - we will need this if we have to unmerge frameshifted exons later
    my $orig_tend = $translation->end;

    # stay with being strict about genewise vs cdna coords - may change this later ...
    # the overlapping cdna exon must at least cover the entire genewise_exon
    if ($genewise_exon->start >= $cdna_exon->start && $genewise_exon->end <= $cdna_exon->end){
	
	my $cdna_start     = $cdna_exon->start;
	my $cdna_end       = $cdna_exon->end;
	my $genewise_start = $genewise_exon->start;
	my $genewise_end   = $genewise_exon->end;
	
	
	# modify the coordinates of the first exon in $newtranscript
	my $ex = $transcript->start_Exon;
	
	$ex->start($cdna_start);
	$ex->end($cdna_end);
	
	# need to explicitly set the translation start & end exons here.
	$translation->start_Exon($ex);
	
	# end_exon may be adjusted by 3' coding exon frameshift expansion. Ouch.

	$translation->end_Exon($ex);

	# need to deal with translation start and end this time - varies depending on strand
	
	############################################################
	#FORWARD:
	if($genewise_exon->strand == 1){
	  my $diff   = $genewise_start - $cdna_start;
	  my $tstart = $translation->start;
	  my $tend   = $translation->end;
	
	  $translation->start($tstart + $diff);
	  $translation->end($tend + $diff);
	
	  throw("Forward strand: setting very dodgy translation start: " . $translation->start.  "\n") unless $translation->start > 0;
	  throw("Forward strand: setting dodgy translation end: " . $translation->end . " exon_length: " . $translation->end_Exon->length . "\n") unless $translation->end <= $translation->end_Exon->length;
	}
	
	############################################################
	#REVERSE:
	elsif($genewise_exon->strand == -1){
	  my $diff   = $cdna_end - $genewise_end;
	  my $tstart = $translation->start;
	  my $tend   = $translation->end;
	  $translation->start($tstart+$diff);
	  $translation->end($tend + $diff);
	
	  throw("Reverse strand: setting very dodgy translation start: " . $translation->start.  "\n") unless $translation->start > 0;
	  throw("Reverse strand: setting dodgy translation end: " . $translation->end . " exon_length: " . $translation->end_Exon->length . "\n") unless $translation->end <= $translation->end_Exon->length;
	}
	
	# expand frameshifted single exon genewises back from one exon to multiple exons

	if($ex->sub_SeqFeature && scalar($ex->sub_SeqFeature) > 1){
	  print STDERR "frameshift in a single exon genewise\n";
	  my @sf = $ex->sub_SeqFeature;
	  
	  # save current start and end of modified exon
	  my $cstart   = $ex->start;
	  my $cend     = $ex->end;
	  my $exlength = $ex->length;
	
	  # get first exon - this has same id as $ex
	  my $first = shift(@sf);
	  $ex->end($first->end); # NB end has changed!!!
	  # don't touch start; no need to modify translation start
	
	  # get last exon
	  my $last = pop(@sf);
	  $last->end($cend);
	  $transcript->add_Exon($last);
	
	  # and adjust translation end - the end is still relative to the merged genewise exon
	  $translation->end_Exon($last);
	
	  # put back the original end translation
	  $translation->end($orig_tend);
	
	  # get any remaining exons
	  foreach my $s(@sf){
	    $transcript->add_Exon($s);
	    $transcript->sort;
	  }

	  $ex->flush_sub_SeqFeature;
	}
	
	# need to add back exons, both 5' and 3'
	$self->add_5prime_exons($transcript, $exoncount, @cdna_exons);
	$self->add_3prime_exons($transcript, $exoncount, @cdna_exons);
	
      }
    
    return ($transcript,0);
  }

# this method will actually do the combination of both cdna and genewise gene.
# Note that if there is a match on one end but not on the other, the
# code will extend one end, but will leave the other as it is in the
# genewise genes. This will explit cdna matches that look fine on one end
# and we disregard the mismatching part.

############################################################

sub transcript_from_multi_exon_genewise {
  my ($self, $current_exon, $transcript, $translation, $exoncount, $genewise_transcript, $cdna_transcript) = @_;

  # $current_exon is the exon one the cdna_transcript we are in at the moment
  # $exoncount is the position of the cdna exon in the array

  my @genewise_exons = @{$genewise_transcript->get_all_Exons};

  my @cdna_exons = @{$cdna_transcript->get_all_Exons};

  # in order to match a starting genewise exon with a cdna exon, we need to have
  # a. exactly coinciding exon ends
  # b. exon starts lying within $exon_slop bp of each other.
  # previously we had required cdna start to be strictly <= genewise start, but this will lose us some valid UTRs
  # substitute "end" for "start" for 3' ends of transcripts

  # compare to the first genewise exon
  if($genewise_exons[0]->strand == 1){
    return $self->transcript_from_multi_exon_genewise_forward($current_exon, $transcript, $translation, $exoncount, $genewise_transcript, $cdna_transcript);
  }
  elsif( $genewise_exons[0]->strand == -1 ){
    return $self->transcript_from_multi_exon_genewise_reverse($current_exon, $transcript, $translation, $exoncount, $genewise_transcript, $cdna_transcript);
  }
}

############################################################

sub transcript_from_multi_exon_genewise_forward{
  my ($self, $current_exon, $transcript, $translation, $exoncount, $genewise_transcript, $cdna_transcript) = @_;

  my $modified_peptide = 0;

  my @genewise_exons = @{$genewise_transcript->get_all_Exons};

  my @cdna_exons = @{$cdna_transcript->get_all_Exons};

  # save out current translation->end - we'll need it if we have to expand 3prime exon later
  my $orig_tend = $translation->end;

  ###################
  my $exon_slop = 20;
  ###################

  ############### 5_PRIME:
  if (#they have a coincident end
      $genewise_exons[0]->end == $current_exon->end &&

      # either cdna exon starts before genewise exon
      ($current_exon->start <= $genewise_exons[0]->start ||

       # or cdna exon is a bit shorter but there are spliced UTR exons as well
       (abs($current_exon->start - $genewise_exons[0]->start) <= $exon_slop && 
	$current_exon != $cdna_exons[0]))){

    my $current_start  = $current_exon->start;
    my $genewise_start = $genewise_exons[0]->start;

    # this exon will be the start of translation, convention: phase = -1
    my $ex = $transcript->start_Exon;
    $ex->phase(-1);

    # modify the coordinates of the first exon in $newtranscript if
    # cdna is larger on this end than genewise
    if ( $current_exon->start < $genewise_exons[0]->start ){
      $ex->start($current_exon->start);
    }
    elsif( $current_exon->start == $genewise_exons[0]->start ){
      $ex->start($genewise_start);
      $ex->phase($genewise_exons[0]->phase);
    }
    # if the cdna exon starts after the genewise exon,
    # modify the start only if this cdna exon is not the first of the transcript
    elsif(  $current_start > $genewise_start && $exoncount != 0 ) {
      $ex->start($current_exon->start);
    }

    # add all the exons from the cdna transcript, previous to this one
    Bio::EnsEMBL::Pipeline::Tools::ExonUtils->_transfer_supporting_evidence($current_exon, $ex);
    $self->add_5prime_exons($transcript, $exoncount, @cdna_exons);

    # fix translation start 
    if($genewise_start >= $current_start){
      # take what it was for the genewise gene, and add on the extra
      my $tstart = $translation->start;

      #print STDERR "Forward 5': original translation start: $tstart ";
      $tstart += ($genewise_start - $current_start);
      $translation->start($tstart);
      #print STDERR "re-setting translation start to: $tstart\n";
    }

    ############################################################
    # only trust a smaller cdna exon if it is not the first of the transcript
    # (it could be a truncated cdna)
    elsif($genewise_start < $current_start && $exoncount != 0){

      $modified_peptide = 1;
      print STDERR "SHORTENING GENEWISE TRANSLATION - 5'\n";

      # genewise has leaked over the start. Tougher call - we need to take into account the
      # frame here as well
      print STDERR "genewise exon starts: $genewise_start < new start: $current_start\n";
      print STDERR "modifying exon, as cdna exon is not the first of transcript-> exoncount = $exoncount\n";

      # $diff is the number of bases we chop from the genewise exon
      my $diff   = $current_start - $genewise_start;
      my $tstart = $translation->start;
      warning("this is a case where genewise translation starts at $tstart > 1") if ($tstart>1);
      print STDERR "genewise translation start: ".$tstart."\n";
      print STDERR "start_exon: " . $translation->start_Exon->start .
	           "-" . $translation->start_Exon->end .
	           " length: " . ($translation->start_Exon->end - $translation->start_Exon->start + 1) .
	           " phase: " . $translation->start_Exon->phase .
	           " end_phase: " . $translation->start_Exon->end_phase."\n";

      if($diff % 3 == 0) { 
	# we chop exactily N codons from the beginning of translation
	$translation->start(1);
	}
      elsif ($diff % 3 == 1) {
	# we chop N codons plus one base
	$translation->start(3);
      }
      elsif ($diff % 3 == 2) {
	# we chop N codons plus 2 bases
	$translation->start(2);
      }
      else {
	$translation->start(1);
	warning("very odd - $diff mod 3 = " . $diff % 3 . "\n");
      }
    }

    else{
      print STDERR "genewise exon starts: $genewise_start > new start: $current_start";
      print STDERR "but cdna exon is the first of transcript-> exoncount = $exoncount, so we don't modify it\n";
    }
    throw("setting very dodgy translation start: " . $translation->start.  "\n") unless $translation->start > 0;

  } # end 5' exon

  ############### 3_PRIME:
  elsif (# they have coincident start
	 $genewise_exons[$#genewise_exons]->start == $current_exon->start &&
	
	 # either e2g exon ends after genewise exon
	 ($current_exon->end >= $genewise_exons[$#genewise_exons]->end ||
	
	    # or we allow to end before if there are UTR exons to be added
	    (abs($current_exon->end - $genewise_exons[$#genewise_exons]->end) <= $exon_slop &&
	     $current_exon != $cdna_exons[$#cdna_exons]))){

      my $end_translation_shift = 0;

      # modify the coordinates of the last exon in $newtranscript
      # cdna is larger on this end than genewise.
      my $ex = $transcript->end_Exon;

      # this exon is the end of translation, convention: end_phase = -1
      $ex->end_phase(-1);

      if ( $current_exon->end > $genewise_exons[$#genewise_exons]->end ){
	$ex->end($current_exon->end);
      }
      elsif( $current_exon->end == $genewise_exons[$#genewise_exons]->end ){
	$ex->end($genewise_exons[$#genewise_exons]->end);
	$ex->end_phase($genewise_exons[$#genewise_exons]->end_phase);
      }

      # if the cdna exon ends before the gw exon,
      # modify the end only if this cdna exon is not the last of the transcript
      elsif ( $current_exon->end < $genewise_exons[$#genewise_exons]->end && $exoncount != $#cdna_exons ){
	
	$modified_peptide = 1;
	print STDERR "SHORTENING GENEWISE TRANSLATION - 3'\n";
	  ## fix translation end iff genewise has leaked over - will need truncating
	  my $diff   = $genewise_exons[$#genewise_exons]->end - $current_exon->end;
	  print STDERR "diff: $diff\n";
	  my $tend   = $translation->end;
	
	  my $genewise_exon_length   = $genewise_exons[$#genewise_exons]->end - $genewise_exons[$#genewise_exons]->start + 1;
	  my $cdna_exon_length       = $current_exon->end - $current_exon->start + 1;
	  print STDERR "genewise exon length  : $genewise_exon_length\n";
	  print STDERR "cdna exon length: $cdna_exon_length\n";
	
	  my $length_diff = $genewise_exon_length - $cdna_exon_length;
	  print STDERR "length diff: ".$length_diff."\n"; # should be == diff
	
	  $ex->end($current_exon->end);
	
	  if($diff % 3 == 0) {
	    # we chop exactily N codons from the end of the translation
	    # so it can end where the cdna exon ends
	    $translation->end($cdna_exon_length);
	    $end_translation_shift = $length_diff;
	
	  }
	  elsif ($diff % 3 == 1) {
	    # we chop N codons plus one base 
	    # it should end on a full codon, so we need to end translation 2 bases earlier:
	    $translation->end($cdna_exon_length - 2);
	    $end_translation_shift = $length_diff + 2;
	  }
	  elsif ($diff % 3 == 2) {
	    # we chop N codons plus 2 bases
	    # it should end on a full codon, so we need to end translation 1 bases earlier:
	    $translation->end($cdna_exon_length - 1);
	    $end_translation_shift = $length_diff + 1;
	  }
	  else {
	    # absolute genebuild paranoia 8-)
	    $translation->end($cdna_exon_length);
	    warning("very odd - $diff mod 3 = " . $diff % 3 . "\n");
	  }
	  print STDERR "Forward: translation end set to : ".$translation->end."\n";

      }
      # need to explicitly set the translation end exon for translation to work out
      my $end_ex = $transcript->end_Exon;
      $translation->end_Exon($end_ex);

      # strand = 1
      my $expanded = $self->expand_3prime_exon($ex, $transcript, 1);
      if($expanded){
	# set translation end to what it originally was in the unmerged genewise gene
	# taking into account the diff
	print STDERR "Forward: expanded 3' exon, re-setting end of translation from ".$translation->end." to orig_end ($orig_tend)- ( length_diff + shift_due_to_phases ) ($end_translation_shift)".($orig_tend - $end_translation_shift)."\n";
	$translation->end($orig_tend - $end_translation_shift);
      }

      # finally add any 3 prime e2g exons
      Bio::EnsEMBL::Pipeline::Tools::ExonUtils->_transfer_supporting_evidence($current_exon, $ex);
      $self->add_3prime_exons($transcript, $exoncount, @cdna_exons);

    } # end 3' exon
 # print "TRANSCRIPT MULTI EXON FORWARD ANALYSIS: " ,$transcript->analysis,"\n";
  return ($transcript,$modified_peptide);
}

##################################################

sub transcript_from_multi_exon_genewise_reverse{
  my ($self, $current_exon, $transcript, $translation, $exoncount, $genewise_transcript, $cdna_transcript) = @_;

  my $modified_peptide = 0;

  my @genewise_exons = @{$genewise_transcript->get_all_Exons};

  my @cdna_exons = @{$cdna_transcript->get_all_Exons};

  # save out current translation->end - we'll need it if we have to expand 3prime exon later
  my $orig_tend = $translation->end;


  ###################
  my $exon_slop = 20;
  ###################

  ####################### 5_PRIME:
  if ($genewise_exons[0]->start == $current_exon->start && 
      # either cdna exon ends after genewise exon
      ($current_exon->end >= $genewise_exons[0]->end ||
       # or there are UTR exons to be added
       (abs($current_exon->end - $genewise_exons[0]->end) <= $exon_slop &&
	$current_exon != $cdna_exons[0]))){

    # sort out translation start
    my $tstart = $translation->start;
    if($current_exon->end >= $genewise_exons[0]->end){
      # take what it was for the genewise gene, and add on the extra
      $tstart += $current_exon->end - $genewise_exons[0]->end;
      $translation->start($tstart);
    }
    elsif( $current_exon->end < $genewise_exons[0]->end && $current_exon != $cdna_exons[0] ){
      # genewise has leaked over the start. Tougher call - we need to take into account the 
      # frame here as well
      $modified_peptide = 1;
      print STDERR "SHORTENING GENEWISE TRANSLATION\n";
      print STDERR "In Reverse strand. genewise exon ends: ".$genewise_exons[0]->end." > cdna exon end: ".$current_exon->end."\n";
      print STDERR "modifying exon, as cdna exon is not the first of transcript-> exoncount = $exoncount\n";

      my $diff           = $genewise_exons[0]->end - $current_exon->end;
      my $genewise_start = $genewise_exons[0]->end;
      my $current_start  = $current_exon->end;
      my $tstart         = $translation->start;

      if    ($diff % 3 == 0) { $translation->start(1); }
      elsif ($diff % 3 == 1) { $translation->start(3); }
      elsif ($diff % 3 == 2) { $translation->start(2); }
      else {
	$translation->start(1);
	warning("very odd - $diff mod 3 = " . $diff % 3 . "\n");}
    }

    throw("setting very dodgy translation start: " . $translation->start.  "\n") unless $translation->start > 0;

    # this exon is the start of translation, convention: phase = -1
    my $ex = $transcript->start_Exon;
    $ex->phase(-1);

    # modify the coordinates of the first exon in $newtranscript
    if ( $current_exon->end > $genewise_exons[0]->end){
      $ex->end($current_exon->end);
      $ex->phase(-1);
    }
    elsif (  $current_exon->end == $genewise_exons[0]->end){
      $ex->end($genewise_exons[0]->end);
      $ex->phase($genewise_exons[0]->phase);
    }
    elsif (  $current_exon->end < $genewise_exons[0]->end && $current_exon != $cdna_exons[0] ){
      $ex->end($current_exon->end);
    }

    # need to explicitly set the translation start exon for translation to work out
    $translation->start_Exon($ex);

    Bio::EnsEMBL::Pipeline::Tools::ExonUtils->_transfer_supporting_evidence($current_exon, $ex);
    $self->add_5prime_exons($transcript, $exoncount, @cdna_exons);

  }
  # end 5' exon

  ###################### 3_PRIME:
  elsif ($genewise_exons[$#genewise_exons]->end == $current_exon->end &&
	 # either cdna exon starts before genewise exon
	 ($current_exon->start <= $genewise_exons[$#genewise_exons]->start ||
	  # or there are UTR exons to be added
	  (abs($current_exon->start - $genewise_exons[$#genewise_exons]->start) <= $exon_slop &&
	   $current_exon != $cdna_exons[$#cdna_exons]))){

    my $end_translation_shift = 0;

    # this exon is the end of translation, convention: end_phase = -1
    my $ex = $transcript->end_Exon;
      $ex->end_phase(-1);

    # modify the coordinates of the last exon in $newtranscript
    if ( $current_exon->start < $genewise_exons[$#genewise_exons]->start ){
      # no need to modify translation->end as the 'end' of this exon has not changed
      $ex->start($current_exon->start);
      $ex->end_phase(-1);
    }
    elsif( $current_exon->start == $genewise_exons[$#genewise_exons]->start){
      $ex->start($genewise_exons[$#genewise_exons]->start);
      $ex->end_phase($genewise_exons[$#genewise_exons]->end_phase);
    }
    # if the cdna exon starts after the genewise exon,
    # modify the end only if this cdna exon is not the last of the transcript
    elsif ( $current_exon->start > $genewise_exons[$#genewise_exons]->start && $exoncount != $#cdna_exons ){

      $modified_peptide = 1;
      print STDERR "SHORTENING GENEWISE TRANSLATION\n";
      print STDERR "In Reverse strand: genewise exon start: ".$genewise_exons[$#genewise_exons]->start." < cdna exon start: ".$current_exon->start."\n";
      print STDERR "modifying exon, as cdna exon is not the last of transcript-> exoncount = $exoncount, and #cdna_exons = $#cdna_exons\n";

	## adjust translation
	my $diff   = $current_exon->start - $genewise_exons[$#genewise_exons]->start;
	print STDERR "diff: $diff\n";
	my $tend   = $translation->end;
	
	my $genewise_exon_length   = $genewise_exons[$#genewise_exons]->end - $genewise_exons[$#genewise_exons]->start + 1;
	my $cdna_exon_length = $current_exon->end - $current_exon->start + 1;
	print STDERR "genewise exon length  : $genewise_exon_length\n";
	print STDERR "cdna exon length: $cdna_exon_length\n";
	
	my $length_diff = $genewise_exon_length - $cdna_exon_length;

	# modify the combined exon coordinate to be that of the cdna
	$ex->start($current_exon->start);

	if($diff % 3 == 0) { 
	  # we chop exactly N codons from the end of the translation
	  # so it can end where the cdna exon ends
	  $translation->end($cdna_exon_length);
	  $end_translation_shift = $length_diff;
	}
	elsif ($diff % 3 == 1) {
	  # we chop N codons plus one base
	  # it should end on a full codon, so we need to end translation 2 bases earlier:
	  $translation->end($cdna_exon_length - 2);
	  $end_translation_shift = $length_diff + 2;
	}
	elsif ($diff % 3 == 2) {
	  # we chop N codons plus 2 bases
	  # it should end on a full codon, so we need to end translation 1 bases earlier:
	  $translation->end($cdna_exon_length - 1);
	  $end_translation_shift = $length_diff + 1;
	}
	else {
	  # absolute genebuild paranoia 8-)
	  $translation->end($cdna_exon_length);
	  warning("very odd - $diff mod 3 = " . $diff % 3 . "\n");
	}
      }	

      # strand = -1
      my $expanded = $self->expand_3prime_exon($ex, $transcript,-1);

      # need to explicitly set the translation end exon for translation to work out
      my $end_ex = $transcript->end_Exon;
      $translation->end_Exon($end_ex);

      if($expanded){
	# set translation end to what it originally was in the unmerged genewise gene
	print STDERR "Reverse: expanded 3' exon, re-setting translation exon ".$translation->end." to original end( $orig_tend ) - shifts_due_to_phases_etc ( $end_translation_shift ) :".($orig_tend - $end_translation_shift)."\n";
	$translation->end($orig_tend - $end_translation_shift);
      }
      Bio::EnsEMBL::Pipeline::Tools::ExonUtils->_transfer_supporting_evidence($current_exon, $ex);
      $self->add_3prime_exons($transcript, $exoncount, @cdna_exons);

    } # end 3' exon
#  print "ANALYSIS FROM TRANSCRIPT MULTI REVERSE: ", $transcript->analysis,"\n";
  return ($transcript,$modified_peptide);
}

=head2 add_5prime_exons

  Description:

  ReturnType : 

=cut

sub add_5prime_exons{
my ($self, $transcript, $exoncount, @cdna_exons) = @_;

      # add all the exons from the cdna transcript, previous to this one
      # db handle will be screwed up, need to make new exons from these
      my $count = 0;
      my $modified = 0;
      while($count < $exoncount){
	my $newexon = new Bio::EnsEMBL::Exon;
	my $oldexon = $cdna_exons[$count];
	$newexon->start($oldexon->start);
	$newexon->end($oldexon->end);
	$newexon->strand($oldexon->strand);

	# these are all 5prime UTR exons
	$newexon->phase(-1);
	$newexon->end_phase(-1);
	$newexon->slice($transcript->slice);
	my %evidence_hash;

	foreach my $sf( @{$oldexon->get_all_supporting_features} ){
	  if ( $evidence_hash{$sf->hseqname}{$sf->hstart}{$sf->hend}{$sf->start}{$sf->end} ){
	    next;
	  }
	  $evidence_hash{$sf->hseqname}{$sf->hstart}{$sf->hend}{$sf->start}{$sf->end} = 1;

	  $newexon->add_supporting_features($sf);
	}

	$transcript->add_Exon($newexon);
	$modified = 1;
	$transcript->sort;
	$count++;
      }
      if ($modified == 1){
       $transcript->translation->start_Exon->phase(-1);
      }
}

# $exon is the terminal exon in the genewise transcript, $transcript. We need
# to expand any frameshifts we merged in the terminal genewise exon.
# The expansion is made by putting $exon to be the last (3' end) component, so we modify its
# start but not its end. The rest of the components are added. The translation end will have to be modified,
# this happens in the method _transcript_from_multi_exon....

############################################################

sub expand_3prime_exon{
  my ($self, $exon, $transcript, $strand) = @_;

  if($exon->sub_SeqFeature && scalar($exon->sub_SeqFeature) > 1){
    print STDERR "expanding 3'prime frameshifted exon $exon in strand $strand: ".
      $exon->start."-".$exon->end." phase: ".$exon->phase." end_phase: ".$exon->end_phase."\n";
    my @sf = $exon->sub_SeqFeature;

    my $last = pop(@sf);

    $exon->start($last->start); # but don't you dare touch the end!
    $exon->dbID($last->dbID);
    $exon->phase($last->phase);

    # add back the remaining component exons
    foreach my $s(@sf){
      $transcript->add_Exon($s);
      $transcript->sort;
    }
    # flush the sub_SeqFeatures so we don't try to re-expand later
    $exon->flush_sub_SeqFeature;
    return 1;
  }

  # else, no expansion
  return 0;
}


############################################################
# $exoncount tells us which position in the array
# of cdna exons corresponds to the end of the genewise transcript so we add back
# exons 3' to that position.
# $exon and $transcript are references to Exon and Transcript objects.

sub add_3prime_exons {
  my ($self, $transcript, $exoncount, @cdna_exons) = @_;
  # need to deal with frameshifts - 3' exon is a special case as its end might have changed

  # add all the exons from the est2genome transcript, subsequent to this one
  my $count = $#cdna_exons;
  my $modified = 0;
  while($count > $exoncount){
    my $newexon = new Bio::EnsEMBL::Exon;
    my $oldexon = $cdna_exons[$count];
    $newexon->start($oldexon->start);
    $newexon->end($oldexon->end);
    $newexon->strand($oldexon->strand);

    # these are all exons with UTR:
    $newexon->phase(-1);
    $newexon->end_phase(-1);
    $newexon->contig($oldexon->contig);

    my %evidence_hash;
    foreach my $sf( @{$oldexon->get_all_supporting_features }){
      if ( $evidence_hash{$sf->hseqname}{$sf->hstart}{$sf->hend}{$sf->start}{$sf->end} ){
	next;
      }
      $evidence_hash{$sf->hseqname}{$sf->hstart}{$sf->hend}{$sf->start}{$sf->end} = 1;

      $newexon->add_supporting_features($sf);
    }

    $transcript->add_Exon($newexon);
    $modified = 1;
    $transcript->sort;
    $count--;
  }
  if ($modified == 1){
    $transcript->translation->end_Exon->end_phase(-1);
  }
}

=head2 remap_genes

=cut

sub remap_genes {
  my ($self) = @_;

  #print "I start remaping genes\n";
  my @newf;
  my $contig = $self->query;

  my @genes = $self->combined_genes;

  my $genecount = 0;
 GENE:
  foreach my $gene (@genes) {
    $genecount++;
    my @t = @{$gene->get_all_Transcripts};
    my $tran = $t[0];

    # check that it translates
    unless(Bio::EnsEMBL::Pipeline::Tools::TranscriptUtils->_check_Translation($tran)){
      print STDERR "rejecting gene while remapping\n";
      next GENE;
    }

    my $transcount = 0;
    foreach my $transcript ( @{$gene->get_all_Transcripts} ){
      $transcount++;
      $transcript->type( $genecount."_".$transcount );

      # set start and stop codons
      $transcript = Bio::EnsEMBL::Pipeline::Tools::TranscriptUtils->set_start_codon($transcript);
      $transcript = Bio::EnsEMBL::Pipeline::Tools::TranscriptUtils->set_stop_codon($transcript);
    }
    
    eval {
      $gene->transform('toplevel');	
    };
    
    if ($gene){
      push(@newf,$gene);
    }
    else{
      print STDERR "transform didn't give anything back on the gene:\n";
    }

    # did we throw exceptions?
    if ($@) {
      print STDERR "Couldn't reverse map gene:  [$@]\n";
    }
  }
  #print "I'm finishing remaping\n";
  return @newf;
}


=head2 _transfer_evidence

 Arg[1]: reference to Bio::EnsEMBL::Tanscript $combined_transcript
 Arg[2]: reference to Bio::EnsEMBL::Transcript $cdna_transcript
 Return: Bio::EnsEMBL::Transcript
 Description: transfers cdna evidence to combined transcript
=cut

sub _transfer_evidence {
  my ($self, $combined_transcript, $cdna_transcript) = @_;
  foreach my $combined_exon(@{$combined_transcript->get_all_Exons}){
    foreach my $cdna_exon(@{$cdna_transcript->get_all_Exons}){
       my $tmp_e_cdna = $cdna_exon->transfer($combined_exon->slice);#added by jb16
       $cdna_exon =$tmp_e_cdna;  #added by jb16
       
       # overlap - feature boundaries may well be wonky
       if($combined_exon->overlaps($cdna_exon)){
         Bio::EnsEMBL::Pipeline::Tools::ExonUtils-> _transfer_supporting_evidence($cdna_exon, $combined_exon);
      }
    }
  }
  return $combined_transcript;
}


# make some lovely genes
sub make_gene{
  my ($self,@transcripts) = @_;

  my $genetype = 'KnownUTR';
  unless ( $genetype ){
    throw("You must define GB_GENEWISE_COMBINED_GENETYPE in Bio::EnsEMBL::Pipeline::Conf::Combined");
  }

  # an analysis should be passed in via the RunnableDB.m parent class:
  my $analysis = $self->analysis;
  unless ($analysis){
    throw("You have to pass an analysis to this RunnableDB through new()");
  }

  my @genes;
  my $count=0;

  
  print "Transcripts to build genes from: ",scalar(@transcripts),"\n";
  foreach my $trans(@transcripts){
    $trans->sort;

    unless ( Bio::EnsEMBL::Pipeline::Tools::TranscriptUtils->_check_Transcript( $trans ) ){
      print STDERR "rejecting transcript\n";
      return;
    }

    my $gene = new Bio::EnsEMBL::Gene;
    $gene->type($genetype);
    $gene->add_Transcript($trans);
    $gene->analysis($analysis);

    # do not modify the analysis of the supporting features
    # they should be the original ones: cdna, targetted_genewise or similarity_genewise

    if($self->validate_gene($gene)){
      push (@genes,$gene);
      $count++;
    }
    

  }

  print STDERR "Produced genes:",scalar(@genes) ,"\n";
  $self->combined_genes(@genes);

}

# Function: get/set for combined gene array

sub combined_genes {
  my ($self, @genes) = @_;

  if (!defined($self->{'_combined_genes'})) {
    $self->{'_combined_genes'} = [];
  }

  if (@genes) {
    push(@{$self->{'_combined_genes'}},@genes);
  }

  return @{$self->{'_combined_genes'}};
}

############################################################

=head2 validate_gene

 Title   : validate_gene
 Usage   : $self->validate_gene($gene)
 Function: checks start and end coordinates of each exon of each transcript are sane
 Example :
 Returns : 1 if gene is valid, otherwise zero
 Args    : $gene: Bio::EnsEMBL::Gene


=cut

sub validate_gene{
  my ($self, $gene) = @_;

  # should be only a single transcript
  my @transcripts = @{$gene->get_all_Transcripts};
  if(scalar(@transcripts) != 1) {
    my $msg = "Rejecting gene - should have one transcript, not " . scalar(@transcripts) . "\n";
    warning($msg);
    return 0;
  }

  foreach my $transcript(@transcripts){
    foreach my $exon(@{$transcript->get_all_Exons}){
      unless ( Bio::EnsEMBL::Pipeline::Tools::ExonUtils->_validate_Exon($exon)){
	my $msg = "Rejecting gene because of invalid exon\n";
	warning($msg);
	return 0;
      }
    }
  }

  return 1;
}

sub make_blat_transcripts {

  my ($self, @blat_results) = @_;

  print STDERR scalar(@blat_results) . " blat results found\n";
  return () unless scalar(@blat_results);

  # take only the best hit
  @blat_results = sort { $b->score <=> $a->score  } @blat_results;

  my $transcript = Bio::EnsEMBL::Transcript->new();

  # get all the features
  my $prev_feature;
  my $prev_exon;

  # sort the features according to the genomic coordinate
  my @sub_features = sort{ $a->feature1->start <=> $b->feature1->start } $blat_results[0]->sub_SeqFeature;
		
 EXON:
  foreach my $sub_feature (@sub_features){
    # each sub_feature is a feature pair
    # make the exon out of the feature1 (the genomic feature)
    my $exon = Bio::EnsEMBL::Exon->new();
    $exon->seqname($sub_feature->feature1->seqname);
    $exon->contig ($sub_feature->feature1->contig);
    $exon->start  ($sub_feature->feature1->start);
    $exon->end    ($sub_feature->feature1->end);
    $exon->strand ($sub_feature->feature1->strand);
    my $strand = $exon->strand;

    # we haven't set any translations here!!
    $exon->phase    (0);
    $exon->end_phase(0);
    # score is actually the coverage for the entire rna/est transcript
    $exon->score      ($sub_feature->feature1->score);
    $exon->adaptor    ($self->db->get_ExonAdaptor);

    # what about the supporting evidence?
    my @supp_features = ($sub_feature);
    my $supp_feature;
    eval{
      $supp_feature = Bio::EnsEMBL::DnaDnaAlignFeature->new( -features => \@supp_features);
    };
    if ( $@ || !defined $supp_feature ){
      warning("could not create supporting feature:\n$@");
      return undef;
    }

    $supp_feature->contig     ($exon->contig);
    $supp_feature->seqname    ($sub_feature->feature1->seqname);
    $supp_feature->hseqname   ($sub_feature->feature2->seqname);
    $supp_feature->score      ($sub_feature->feature2->score);
    $supp_feature->percent_id ($sub_feature->feature2->percent_id);
    $supp_feature->analysis   ($self->analysis );
    $exon->add_supporting_features($supp_feature);

    if ( $prev_exon &&  ( $exon->start - $prev_exon->end ) < 10  ){
      $prev_exon->end( $exon->end );
      $prev_exon->add_supporting_features( @{$exon->get_all_supporting_features} );
    }
    else{
      $transcript->add_Exon($exon);
      $prev_exon = $exon;
    }
  }

  # put sequence to the transcript:
  my $slice = $self->query;
  foreach my $exon (@{$transcript->get_all_Exons}){
    $exon->contig($slice);
    foreach my $evi (@{$exon->get_all_supporting_features}){
      $evi->contig($slice);
    }
  }

  # check the splice sites 
  # to see if the transcript is in the correct strand
  my $checked_transcript = $self->check_splice_sites( $transcript );

  return $checked_transcript;
}


=head2 check_splice_sites

We want introns of the form:

    ...###GT...AG###...   ...###AT...AC###...   ...###GC...AG###...

if we see introns like these:

    ...###CT...AC###...   ...###GT...AT###...   ...###CT...GC###...

we need to set the strand to the opposite. This can happen when
an est/cdna is annotated backwards in the db, if blat reverse
complement it to map it, it will find exactily the same exon
sequence of an homolog annotated forward, but in the opposite
strand. As blat does not reconfirm splice sites like est2genome,
we need to do it ourselves. Exonerate will do this work for you.

=cut

sub check_splice_sites{
  my ($self, $transcript) = @_;
  $transcript->sort;

  my $strand = $transcript->start_Exon->strand;
  my @exons  = @{$transcript->get_all_Exons};
  my $introns  = scalar(@exons) - 1 ; 
  if ( $introns <= 0 ){
    return $transcript;
  }

  my $correct  = 0;
  my $wrong    = 0;
  my $other    = 0;

  # all exons in the transcripts are in the same seqname coordinate system:
  my $slice = $self->query;
  my $chr_start        = $slice->chr_start;
  my $chr_name         = $slice->chr_name;

  if ($strand == 1 ){
	
  INTRON:
    for (my $i=0; $i<$#exons; $i++ ){
      my $upstream_exon   = $exons[$i];
      my $downstream_exon = $exons[$i+1];
      my $upstream_site;
      my $downstream_site;

      # coordinates are slice relative; need to get them in chr coords

      my $upstream_start   = $chr_start + $upstream_exon->end     + 1;
      my $upstream_end     = $chr_start + $upstream_exon->end     + 2;
      my $downstream_start = $chr_start + $downstream_exon->start - 2;
      my $downstream_end   = $chr_start + $downstream_exon->start - 1;

      eval{
	$upstream_site = 
	  $self->get_chr_subseq( $chr_name, $upstream_start, $upstream_end );
	$downstream_site = 
	  $self->get_chr_subseq( $chr_name, $downstream_start, $downstream_end );
      };
      unless ( $upstream_site && $downstream_site ){
	print STDERR "problems retrieving sequence for splice sites\n$@";
	next INTRON;
      }
#      print STDERR "upstream $upstream_site, downstream: $downstream_site\n";
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

      my $upstream_start   = $chr_start + $upstream_exon->start - 2;
      my $upstream_end     = $chr_start + $upstream_exon->start - 1;
      my $downstream_start = $chr_start + $downstream_exon->end + 1;
      my $downstream_end   = $chr_start + $downstream_exon->end + 2;


      eval{
	$up_site = 
	  $self->get_chr_subseq( $chr_name, $upstream_start, $upstream_end );
	$down_site = 
	  $self->get_chr_subseq( $chr_name, $downstream_start, $downstream_end );
      };
      unless ( $up_site && $down_site ){
	print STDERR "problems retrieving sequence for splice sites\n$@";
	next INTRON;
      }
      ( $upstream_site   = reverse(  $up_site  ) ) =~ tr/ACGTacgt/TGCAtgca/;
      ( $downstream_site = reverse( $down_site ) ) =~ tr/ACGTacgt/TGCAtgca/;

#      print STDERR "upstream $upstream_site, downstream: $downstream_site\n";
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
  unless ( $introns == $other + $correct + $wrong ){
    print STDERR "STRANGE: introns:  $introns, correct: $correct, wrong: $wrong, other: $other\n";
  }
  if ( $wrong > $correct ){
    print STDERR "changing strand\n";
    return  $self->change_strand($transcript);
  }
  else{
    return $transcript;
  }
}

############################################################

=head2 change_strand

    this method changes the strand of the exons

=cut

sub change_strand{
    my ($self,$transcript) = @_;
    my $original_strand = $transcript->start_Exon->strand;
    my $new_strand      = (-1)*$original_strand;
    foreach my $exon (@{$transcript->get_all_Exons}){
	$exon->strand($new_strand);
    }
    $transcript->sort;
    return $transcript;
}

=head2 get_chr_subseq

It return a piece of chromosome sequence specified
by start, end and strand. Its purpose is to
check the splice site sequences and it needs to know
where the dumps of the chromosomes are (fasta files),
which reads from the variable EST_GENOMIC in EST_GeneBuilder_conf.pm
strand is not used.

=cut

sub get_chr_subseq{
  my ( $self, $chr_name, $start, $end, $strand ) = @_;



  my $chr_file = $GB_FPCDIR."/".$chr_name.".fa";
  my $command = "chr_subseq $chr_file $start $end |";

  open( SEQ, $command ) || throw("Error running chr_subseq within KnownUTRs");
  my $seq = uc <SEQ>;
  chomp $seq;
  close( SEQ );

  return $seq;
}

sub tmpfile{
  my ($self, $filename) = @_;
  if($filename){
    $self->{'_tmpfile'} = $filename;
  }
  return $self->{'_tmpfile'};
}


sub populate_kill_list {
  my ($self) = @_;

  my $kill_list_object = Bio::EnsEMBL::KillList::KillList->new(-TYPE => 'protein');
  my %kill_list = %{$kill_list_object->get_kill_list()};

  return \%kill_list;
}

=head2 genewise_db
  Arg [1]    : 
  Description: get/set for db storing genewise alignments
  Returntype : 
  Exceptions : 
  Example    : 
 
=cut

sub genewise_db {
    my( $self, $genewise_db ) = @_;

    if ($genewise_db){
      $genewise_db->isa("Bio::EnsEMBL::DBSQL::DBAdaptor")
        || throw("Input [$genewise_db] isn't a ".
                        "Bio::EnsEMBL::DBSQL::DBAdaptor");
      $self->{_genewise_db} = $genewise_db;
    }
    if(!$self->{_genewise_db}){
      $self->{_genewise_db} = new Bio::EnsEMBL::DBSQL::DBAdaptor
        (
         '-host'   => $GB_GW_DBHOST,
         '-user'   => $GB_GW_DBUSER,
         '-pass'   => $GB_GW_DBPASS,
         '-port'   => $GB_GW_DBPORT,
         '-dbname' => $GB_GW_DBNAME,
         '-dnadb' => $self->db,
        );
    }
    return $self->{_genewise_db};
}

############################################################

=head2 _recalculate_translation

  
 Arg[1]: a transcript object
 Arg[2]: the strand where the transcript sits
 Return: a brand new transcript object
 Description: a transcript is used as evidence for genomewise
              to recalculate the ORF. The idea is to use this when
              the peptide has been shortened, due to a genewise model
              being incompatible with the cdna splicing. This can happen 
              when genewise cannot find very short exons
              and attaches them to one of the flanking exons.
              We tell genomewise to keep the splice boundaries pretty much
              static, so that we preserve the original splicing structure.

=cut

sub _recalculate_translation{
  my ($self,$mytranscript,$strand) = @_;

  my $this_is_my_transcript = Bio::EnsEMBL::Pipeline::Tools::TranscriptUtils->_clone_Transcript($mytranscript);
  my $transcript;

  my $slice = $mytranscript->slice;
  my $inverted_slice = $slice->invert;
  
  # the genomic sequence to be used with Genomewise (a PrimarySeq)

  # genomewise doesn't know about strands, we need to put everything in forward strand:
  my $genomic_sequence;

  if ( $strand == -1 ){

      print STDERR "In reverse strand: inverting gene\n";
    $genomic_sequence = $inverted_slice;

    my $mygene               = Bio::EnsEMBL::Gene->new();
    $mygene->add_Transcript($mytranscript);
    my $gene                 = $mygene->transform($inverted_slice);
    my @inverted_transcripts = @{$gene->get_all_Transcripts};
    $transcript              = $inverted_transcripts[0];
  }
  else{
      print STDERR "In forward strand:\n";
    $transcript       = $mytranscript;
    $genomic_sequence = $slice;
  }

  my @transcripts;
  push(@transcripts,$transcript);
  my $runnable = Bio::EnsEMBL::Pipeline::Runnable::MiniGenomewise->new(
								       -genomic     => $genomic_sequence,
								       -transcripts => \@transcripts,
								       -smell       => 0,
								      );
  eval{
      $runnable->run;
  };
  if ($@){
      print STDERR $@;
  }
  my @trans = $runnable->output;
  unless ( scalar(@trans) == 1 ){
      warning("Something went wrong running Genomewise. Got ".scalar(@trans).
		  " transcripts. returning without modifying the translation\n");
      return $mytranscript;
  }

  my $newtranscript;

  # if in the reverse strand, put it back in the original slice
  if ( $strand == -1 ){
    my $gene = Bio::EnsEMBL::Gene->new();
    $gene->add_Transcript($trans[0]);
    my $newgene        = $gene->transform($slice);
    my @newtranscripts = @{$newgene->get_all_Transcripts};
    $newtranscript     = $newtranscripts[0];
  }
  else{
    $newtranscript = $trans[0];
  }

  # check that everything is sane:
  unless (Bio::EnsEMBL::Pipeline::Tools::TranscriptUtils->_check_Translation($newtranscript)){
      print STDERR "problem with the translation. Returning the original transcript\n";
      return $this_is_my_transcript;
  }
  return $newtranscript;
}


1;
