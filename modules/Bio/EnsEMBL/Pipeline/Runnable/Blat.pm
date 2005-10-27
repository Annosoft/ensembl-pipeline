#
# Written by Eduardo Eyras
#
# Copyright GRL/EBI 2002
#
# You may distribute this module under the same terms as perl itself
#
# POD documentation - main docs before the code

=pod

=head1 NAME

Bio::EnsEMBL::Pipeline::Runnable::Blat

=head1 SYNOPSIS

  my $runnable = Bio::EnsEMBL::Pipeline::Runnable::Blat->new(
								 -database    => $database,
								 -query_seqs  => \@sequences,
								 -query_type  => $self->query_type,
								 -target_type => $self->target_type,
								 -blat        => $self->blat,
								 -options     => $self->options,
								);

 $runnable->run; #create and fill Bio::Seq object
 my @results = $runnable->output;
 
 where @results is an array of SeqFeatures, each one representing an aligment (e.g. a transcript), 
 and each feature contains a list of alignment blocks (e.g. exons) as sub_SeqFeatures, which are
 in fact feature pairs.
 
=head1 DESCRIPTION

Blat takes a Bio::Seq (or Bio::PrimarySeq) object and runs Blat
against a set of sequences.  The resulting output file is parsed
to produce a set of features.

=head1 CONTACT

ensembl-dev@ebi.ac.uk

=head1 APPENDIX

The rest of the documentation details each of the object methods.
Internal methods are usually preceded with a _

=cut

package Bio::EnsEMBL::Pipeline::Runnable::Blat;

use vars qw(@ISA);
use strict;

use Bio::EnsEMBL::Utils::Exception qw(throw warning);
use Bio::EnsEMBL::Utils::Argument qw(rearrange);
use Bio::EnsEMBL::Pipeline::RunnableI;
use Bio::EnsEMBL::SeqFeature;
use Bio::EnsEMBL::FeaturePair;
use Bio::EnsEMBL::Analysis;
use Bio::EnsEMBL::Root;
use Bio::PrimarySeqI;
use Bio::SeqI;

@ISA = qw(Bio::EnsEMBL::Pipeline::RunnableI);


sub new {
  my ($class,@args) = @_;
  my $self = $class->SUPER::new(@args);
  #added a parse clause to remove covered alignments, should work without it though
  my ($database, $query_seqs, $query_file, $query_type, $target_type,
      $blat, $options, $parse) = rearrange([qw(
												  DATABASE
												  QUERY_SEQS
                          QUERY_FILE
												  QUERY_TYPE
												  TARGET_TYPE
												  BLAT
												  OPTIONS
												  PARSE
												 )
											      ], @args);
  
  # must have a target and a query sequences
  unless( $query_seqs ){
#    throw("Blat needs a query_seqs: $query_seqs");
  }
  $self->query_seqs(@{$query_seqs});
  $self->query_file($query_file) if (defined($query_file));
  
  # you can pass a sequence object for the target or a database (multiple fasta file);
  if( $database ){
    $self->database( $database );
  }
  else{
    throw("Blat needs a target - database: $database");
  }
  
  # Target type: dna  - DNA sequence
  #              prot - protein sequence
  #              dnax - DNA sequence translated in six frames to protein
  #              The default is dna
  if ($target_type){
    $self->target_type($target_type);
  }
  #else{
  #  print STDERR "Defaulting target type to dna\n";
  #  $self->target_type('dna');
  #}

  # Query type: dna  - DNA sequence
  #             rna  - RNA sequence
  #             prot - protein sequence
  #             dnax - DNA sequence translated in six frames to protein
  #             rnax - DNA sequence translated in three frames to protein
  #             The default is dna
  if ($query_type){
    $self->query_type($query_type);
  }
  #else{
  #  print STDERR "Defaulting query type to dna\n";
  #  $self->query_type('dna');
  #}

  # can choose which blat to use
  $blat ||= 'blat';
  $self->blat($self->find_executable($blat));
  #To parse or not to parse
   if ($parse){
    $self->parse($parse);
  }
 # can add extra options as a string
  if ($options){
    $self->options($options);
  }
  return $self;
}

############################################################
#
# Analysis methods
#
############################################################

=head2 run

Usage   :   $obj->run($workdir, $args)
Function:   Runs blat script and puts the results into the file $self->results
            It calls $self->parse_restuls, and results are stored in $self->output
            reads the Blat output (in PSL format or psLayout ) which has been written to
             a local file $self->results. can accept filenames, filehandles or pipes (\*STDIN)


=cut
  
sub run {
  my ($self) = @_;
    
  my $dir         = $self->workdir();
  my $blat        = $self->blat;
  my $query_type  = $self->query_type;
  my $target_type = $self->target_type;
  my $parse	  = $self->parse;
  my @query_seqs  = $self->query_seqs;
  my $query_file  = $self->query_file;
  my $remove_file = undef;

  
  # set the working directory (usually /tmp)
  $self->workdir('/tmp') unless ($self->workdir());
  #print STDERR" working directory ".$self->workdir()."\n";

  # results go here:
  $self->results($self->workdir()."/results.$$");
  
  # target sequence
  my $target;
  if ( $self->database ){
    $target = $self->database;
  }
  elsif( $self->target_seq ){
    
    # write the target sequence into a temporary file then
    $target = "$dir/target_seq.$$";
    open( TARGET_SEQ,">$target") || throw("Could not open $target $!");
    my $seqout = Bio::SeqIO->new('-format' => 'Fasta',
				 '-fh'     => \*TARGET_SEQ);
    $seqout->write_seq($self->target_seq);
    close( TARGET_SEQ );
  }
  
  # write the query sequence into a temporary file then
  if (!defined($query_file)) {
    $query_file = "$dir/query_seqs.$$";
    open( QUERY_SEQ,">$query_file") || throw("Could not open $query_file $!");
    my $seqout = Bio::SeqIO->new('-format' => 'Fasta',
  			       '-fh'     => \*QUERY_SEQ);

    # we write each Bio::Seq sequence in the fasta file $query_file
    foreach my $query_seq ( @query_seqs ){
      $seqout->write_seq($query_seq);
    }
    close( QUERY_SEQ );
    $remove_file = 1; # Request to remove file at the end of the process
  }
  
  #my $parameters = $self->analysis->parameters;

  #my $command ="$blat ".$self->options." -t=$target_type -q=$query_type $target $query_file stdout ";
  my $command ="$blat -out=pslx ".$self->options." -t=$target_type -q=$query_type $target $query_file stdout ";
  #my $command ="$blat ".$self->options." $parameters $target $query_file ".$self->results; 

  print STDERR "running blat: $command\n";
  
  open( BLAT, "$command |" );
    
  #################### Parse Results ####################

#  my @features_within_features;
  
   	my $prev_query='a';
	my $prev_hit='b';
	my $hit_count= -1; #so that they'll start at 0
	my $align_count = -1;
	my @features;
    	my @data;
	my $filesize=0;

  while (<BLAT>){
	#print STDERR "open BLAT\n";
    
    ############################################################
    #  PSL lines represent alignments and are typically taken from files generated 
    # by BLAT or psLayout. See the BLAT documentation for more details. 
    #
    # 1.matches - Number of bases that match that aren't repeats 
    # 2.misMatches - Number of bases that don't match 
    # 3.repMatches - Number of bases that match but are part of repeats 
    # 4.nCount - Number of 'N' bases 
    # 5.qNumInsert - Number of inserts in query 
    # 6.qBaseInsert - Number of bases inserted in query 
    # 7.tNumInsert - Number of inserts in target 
    # 8.tBaseInsert - Number of bases inserted in target 
    # 9.strand - '+' or '-' for query strand. In mouse, second '+'or '-' is for genomic strand 
    #10.qName - Query sequence name 
    #11.qSize - Query sequence size 
    #12.qStart - Alignment start position in query 
    #13.qEnd - Alignment end position in query 
    #14.tName - Target sequence name 
    #15.tSize - Target sequence size 
    #16.tStart - Alignment start position in target 
    #17.tEnd - Alignment end position in target 
    #18.blockCount - Number of blocks in the alignment 
    #19.blockSizes - Comma-separated list of sizes of each block 
    #20.qStarts - Comma-separated list of starting positions of each block in query 
    #21.tStarts - Comma-separated list of starting positions of each block in target 
    ############################################################
    
    # first split on spaces:
    chomp;  
      
    my (
            $matches,      $mismatches,    $rep_matches, $n_count,  $q_num_insert, $q_base_insert,
            $t_num_insert, $t_base_insert, $strand,      $q_name,   $q_length,     $q_start,
            $q_end,        $t_name,        $t_length,    $t_start,  $t_end,        $block_count,
            $block_sizes,  $q_starts,      $t_starts,    $q_seqs,   $t_seqs
          )
          = split;
	        # print STDERR  "$matches,      $mismatches,    $rep_matches, $n_count, $q_num_insert, $q_base_insert,
            #$t_num_insert, $t_base_insert, $strand,      $q_name,  $q_length,     $q_start,
            #$q_end,        $t_name,        $t_length,    $t_start, $t_end,        $block_count,
            #$block_sizes,  $q_starts,      $t_starts\n";
   
		
#    my $superfeature = Bio::EnsEMBL::SeqFeature->new();
    
    
    #print STDOUT $_."\n";

    # ignore any preceeding text
    unless ( defined($matches) and $matches =~/^\d+$/ ){
      next;
    }
    
    # create as many features as blocks there are in each output line
    my (%feat1, %feat2);
    $feat1{name} = $t_name;
    $feat2{name} = $q_name;
    
    ################
    #Added strand splitter as strand represented by ++ or +- etc
    if (length($strand)>1){
    	($feat2{strand},$feat1{strand}) = split //,$strand; 
   	} else {
    	$feat2{strand}=$strand;
    	$feat1{strand}=1;
  	}
    
    # all the block sizes add up to $matches + $mismatches + $rep_matches
    
    # percentage identity =  ( matches not in repeats + matches in repeats ) / ( alignment length )
    #print STDERR "calculating percent_id and score:\n";
    #print STDERR "matches: $matches, rep_matches: $rep_matches, mismatches: $mismatches, q_length: $q_length\n";
    #print STDERR "percent_id = 100x".($matches + $rep_matches)."/".( $matches + $mismatches + $rep_matches )."\n";
    #my $percent_id = sprintf "%.2f", ( 100 * ($matches + $rep_matches)/( $matches + $mismatches + $rep_matches ) );
    
    # or is it ...?
    ## percentage identity =  ( matches not in repeats + matches in repeats ) / query length
    #my $percent_id = sprintf "%.2d", (100 * ($matches + $rep_matches)/$q_length );
    
    # we put basically score = coverage = ( $matches + $mismatches + $rep_matches ) / $q_length
    #print STDERR "score = 100x".($matches + $mismatches + $rep_matches)."/".( $q_length )."\n";
    
    unless ( $q_length ){
      warning("length of query is zero, something is wrong!");
      next;
    }
    my $score   = sprintf "%.2f", ( 100 * ( $matches + $mismatches + $rep_matches ) / $q_length );
    
    # size of each block of alignment (inclusive)
    my @block_sizes     = split ",",$block_sizes;
    
    # start position of each block (you must add 1 as psl output is off by one in the start coordinate)
    my @q_start_positions = split ",",$q_starts;
    my @t_start_positions = split ",",$t_starts;
    my @q_sequences = split ",",$q_seqs;
    my @t_sequences = split ",",$t_seqs;
    
#    $superfeature->seqname($q_name);
#    $superfeature->score( $score );
#    $superfeature->percent_id( $percent_id );

    # each line of output represents one possible entire aligment of the query (feat1) and the target(feat2)
       
      #### working out the coordinates: #########################
      #
      #                s        e
      #                ==========   EST
      #   <----------------------------------------------------| (reversed) genomic of length L
      #
      #   we would store this as a hit in the reverse strand, with coordinates:
      #
      #   |---------------------------------------------------->
      #                                   s'       e'
      #                                   ==========   EST
      #   where e' = L  - s  
      #         s' = e' - ( e - s + 1 ) + 1
      #
      #   Also, hstrand will be always +1
      ############################################################

    ############################################################


    #NB strand may =++ or +- etc rather than just + or -  
    #
    #if qstrand negative reverse qstarts and blocks and calculate the correct co-ordinates
    #
    #if Tstrand(genomic strand) negative reverse the tstarts and then cal the co-ords
    #
    #if both strands are negative then reverse everything ie blocks and starts before calculating using:
    #
    # newqstart=length - (qstart + blocklength)  
    # newqend = length - qstart
    #NB not sure about when to add the plus 1 -- as psl starts at 0 for start but the end is correct 
    #NB add +1 to the plus strand starts    
    




    my @query_starts; my @target_starts; my @query_ends; my @target_ends; my @reversed_block_sizes;
    my @reversed_q_starts; my @reversed_t_starts;


    if ($feat2{strand} eq '+') { # query in the forward strand

      @query_starts = map {my $val=$_; $val+=1} (@q_start_positions); # use inclusive coord
      if ($feat1{strand} eq '-') { # target in the reverse strand
        for (my $i=0; $i<$block_count; $i++) {
          $query_ends[$i] = $q_start_positions[$i] + $block_sizes[$i];
          $target_ends[$i] = $t_length - $t_start_positions[$i];
          $target_starts[$i] = ($target_ends[$i] - $block_sizes[$i]) + 1;
        }
      } else { # target in the forward strand
        @target_starts = map {my $val=$_; $val+=1} (@t_start_positions); # use inclusive coord
        for (my $i=0; $i<$block_count; $i++) {
          $query_ends[$i] = $q_start_positions[$i] + $block_sizes[$i];
          $target_ends[$i] = $t_start_positions[$i] + $block_sizes[$i];
        }
      }

    } else { # query in the reverse strand

      if ($feat1{strand} eq '-') { 
        for (my $i=0; $i<$block_count; $i++ ) { # target in the reverse strand
          $query_ends[$i] = $q_length - $q_start_positions[$i];
          $query_starts[$i] = ($query_ends[$i] - $block_sizes[$i]) + 1;
          $target_ends[$i] = $t_length - $t_start_positions[$i];
          $target_starts[$i] = ($target_ends[$i] - $block_sizes[$i]) + 1;
        }
      } else { # target in forward strand
        @target_starts= map {my $val=$_; $val+=1} (@t_start_positions); # use inclusive coord
        for (my $i=0; $i<$block_count; $i++ ) {
          $query_ends[$i] = $q_length - $q_start_positions[$i];
          $query_starts[$i] = ($query_ends[$i] - $block_sizes[$i]) + 1;
          $target_ends[$i] = $t_start_positions[$i] + $block_sizes[$i];
        }
      }

    }



    for (my $i=0; $i<$block_count; $i++ ) {
      next if ($block_sizes[$i] < 15);

      $feat2 {start} = $query_starts[$i];
      $feat2 {end}   = $query_ends[$i];
      if ( $query_ends[$i] <  $query_starts[$i]) {
        warning("dodgy feature coordinates: end = $query_ends[$i], start = $query_starts[$i]. Reversing...");
        $feat2 {end}   = $query_starts[$i];
        $feat2 {start} = $query_ends[$i];
      }

      $feat1 {start} = $target_starts[$i];
      $feat1 {end}   = $target_ends[$i];

      my $this_q_bioseq = Bio::Seq->new(
          -seq => $q_sequences[$i],
          -moltype => "dna",
          -alphabet => 'dna',
          -id => "q_seq");
      my $this_t_bioseq = Bio::Seq->new(
          -seq => $t_sequences[$i],
          -moltype => "dna",
          -alphabet => 'dna',
          -id => "t_seq");
      my ($score, $percent_id, $frame) =
          get_best_score_in_all_frames($this_q_bioseq, $this_t_bioseq);
      # we put all the features with the same score and percent_id
      $feat2 {score}   = $score;
      $feat1 {score}   = $feat2 {score};
      $feat2 {percent} = $percent_id;
      $feat1 {percent} = $feat2 {percent};
      
      # other stuff:
      $feat1 {db}         = undef;
      $feat1 {db_version} = undef;
      $feat1 {program}    = 'blat';
      $feat1 {p_version}  = '1';
      $feat1 {source}     = 'blat';
      $feat1 {primary}    = 'similarity';
      $feat2 {source}     = 'blat';
      $feat2 {primary}    = 'similarity';
      
#      my $feature_pair = $self->create_FeaturePair(\%feat1, \%feat2);
#      $superfeature->add_sub_SeqFeature( $feature_pair,'EXPAND');
      
			$align_count++;
			$data[$align_count]={
						qid		=> $feat2{name},
						tid		=> $feat1{name},
						score		=> $score,
						PID		=> $percent_id,
						Q_start		=> $query_starts[$i],
						Q_end		=> $query_ends[$i],
						Q_strand	=> $feat2{strand},
						T_start		=> $target_starts[$i],
						T_end		=> $target_ends[$i],
						T_strand	=> $feat1{strand},
				};
	  }
#    push(@features_within_features, $superfeature);
  }
  close BLAT;
  
 if (defined($parse)){		
	foreach my $out (@data){
		print STDERR $out->{qid}."\tBLAT\tsimilarity\t".$out->{Q_start}."\t".$out->{Q_end}."\t".$out->{tid}."\t".$out->{T_start}."\t".$out->{T_end}."\t".
                      $out->{score}."\t.\t".$out->{T_strand}."\t". $out->{Q_strand}."\t".$out->{PID}."\t.\t.\n"; #this line is the start of a gff line for display
			}
		}
 #get rid of the results file
  unlink $self->results;

  #print STDERR "\n";
  #print STDERR "Features created:\n";
  #foreach my $superf ( @features_within_features ){
   # foreach my $subf ( $superf->sub_SeqFeature ){
    #  print STDERR $subf->gffstring."\n";
    #}
  #}
  
 
  
  # remove interim files (but do not remove the database if you are using one)
  unlink $query_file if ($remove_file);
  
  
 
 
#  $self->output( @features_within_features );


  1;
}

sub get_best_score_in_all_frames {
  my ($seq1, $seq2, $matrix) = @_;

  my @aa_seq1_6fr = Bio::SeqUtils->translate_6frames($seq1);
  my @aa_seq2_6fr = Bio::SeqUtils->translate_6frames($seq2);

  my $score;
  my $perc_id = 0;
  my $frame = 0;
##  my $seqs;
  for (my $i=0; $i<6; $i++) {
    my $this_score = 0;
    my $this_perc_id = 0;
    my $this_seq1 = $aa_seq1_6fr[$i]->seq;
    my $this_seq2 = $aa_seq2_6fr[$i]->seq;
    my $length = length($this_seq1);
    $length = length($this_seq2) if (length($this_seq2) < $length);
    my @this_seq1 = split("", $this_seq1);
    my @this_seq2 = split("", $this_seq2);

    if (defined($matrix)) {
      for (my $j=0; $j<$length; $j++) {
        my $aa1 = $this_seq1[$j];
        my $aa2 = $this_seq2[$j];
        $this_score += $matrix->{$aa1}->{$aa2};
        $this_perc_id++ if ($aa1 eq $aa2);
      }
    } else {
      for (my $j=0; $j<$length; $j++) {
        my $aa1 = $this_seq1[$j];
        my $aa2 = $this_seq2[$j];
        if ($aa1 eq $aa2) {
          $this_score += 2;
          $this_perc_id++;
        } else {
          $this_score--;
        }
      }
    }

    if (!defined($score) or ($this_score > $score)) {
      $score = $this_score;
      if ($length) {
        $perc_id = int(100 * $this_perc_id / $length);
      } else {
        $perc_id = 0;
      }
      $frame = $i;
##      $seqs = $this_seq1."\n".$this_seq2;
    }
  }

  return ($score, $perc_id, $frame);
}


############################################################
#
# get/set methods
#
############################################################

sub query_seqs {
  my ($self, @seqs) = @_;
  if (@seqs){
    unless ($seqs[0]->isa("Bio::PrimarySeqI") || $seqs[0]->isa("Bio::SeqI")){
      throw("query seq must be a Bio::SeqI or Bio::PrimarySeqI");
    }
    push(@{$self->{_query_seqs}}, @seqs) ;
  }
  return @{$self->{_query_seqs} or []};
}

############################################################

sub query_file {
  my ($self, $file) = @_;
  if ($file){
    if (!-e $file or !-s $file) {
      throw("Cannot find query file <$file>");
    }
    $self->{_query_file} = $file;
  }
  return $self->{_query_file};
}

############################################################

sub genomic {
  my ($self, $seq) = @_;
  if ($seq){
    unless ($seq->isa("Bio::PrimarySeqI") || $seq->isa("Bio::SeqI")){
      throw("query seq must be a Bio::SeqI or Bio::PrimarySeqI");
    }
    $self->{_genomic} = $seq ;
  }
  return $self->{_genomic};
}

############################################################

sub blat {
  my ($self, $location) = @_;
  if ($location) {
    throw("Blat not found at $location: $!\n") unless (-e $location);
    $self->{_blat} = $location ;
  }
  return $self->{_blat};
}

############################################################

sub query_type {
  my ($self, $mytype) = @_;
  if (defined($mytype) ){
    my $type = lc($mytype);
    unless( $type eq 'dna' || $type eq 'rna' || $type eq 'prot' || $type eq 'dnax' || $type eq 'rnax' ){
      throw("not the right query type: $type");
    }
    $self->{_query_type} = $type;
  }
  return $self->{_query_type};
}

############################################################

sub target_type {
  my ($self, $mytype) = @_;
  if (defined($mytype) ){
    my $type = lc($mytype);
    unless( $type eq 'dna' || $type eq 'prot' || $type eq 'dnax' ){
      throw("not the right target type: $type");
    }
    $self->{_target_type} = $type ;
  }
  return $self->{_target_type};
}

############################################################

sub options {
  my ($self, $options) = @_;
  if ($options) {
    $self->{_options} = $options ;
  }
  return $self->{_options};
}

############################################################

sub output {
  my ($self, @output) = @_;
  unless( $self->{_output} ){
    $self->{_output} = [];
  }
  if (@output) {
    push( @{$self->{_output}}, @output );
  }
  return @{$self->{_output}};
}

############################################################

sub database {
  my ($self, $database) = @_;
  if ($database) {
    $self->{_database} = $database;
  }
  return $self->{_database};
}

############################################################

############################################################

sub parse {
  my ($self, $parse) = @_;
  if ($parse) {
    $self->{_parse} = $parse;
  }
  return $self->{_parse};
}

############################################################


1;

