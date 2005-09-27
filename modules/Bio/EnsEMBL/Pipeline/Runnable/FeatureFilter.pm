#
# Ensembl module for Bio::EnsEMBL::Pipeline::Runnable::FeatureFilter
#
# Cared for by Ewan Birney <birney@ebi.ac.uk>
#
# Copyright GRL and EBI
#
# You may distribute this module under the same terms as perl itself

# POD documentation - main docs before the code

=head1 NAME

Bio::EnsEMBL::Pipeline::Runnable::FeatureFilter - Filters a search runnable

=head1 SYNOPSIS

   $search = Bio::EnsEMBL::Pipeline::Runnable::FeatureFilter->new(
                                                    -coverage  => 5,
					            -minscore  => 100,
					            -maxevalue => 0.001,
					            -prune     => 1,
						    -hardprune => 1
				                                 );

   my @filteredfeatures = $search->run(@features);

=head1 DESCRIPTION

Filters search results, such as Blast, on several criteria. The most
important ones are minscore, maxevalue, coverage and hardprune.
Crudely, coverage reduces redundant data (e.g., almost-identical ESTs
with different accession numbers), and prune reduces overlapping
features (e.g., hits to a repetitive sequence). If hardprune is in
effect, a separate, final prune-like step is performed across all
features, to ensure no genomic base is covered to more than the
specified depth per strand.

Feature score is assumed to be meaningful and comparable between
features. Hence, only features resulting from the same database
search should be filtered together.

Coverage filtering is compulsory and is intended to reduce excessive
coverage of each strand of the query. In detail, coverage filtering
does this:

  sort hit-sequence-accessions in decreasing order of
  maximum feature score;

  for each strand:

    for each hit-sequence-accession in turn:

      if ( all parts of all features for
      hit-sequence-accession are already covered by
      other features to a depth of <coverage> )

        remove all features for this hit-sequence-accession;

Where two or more hit-sequence-accessions have equal maximum feature
score, secondary sorting is in decreasing order of total score,
followed by alphabetical order of hit-sequence accession number. The
last criterion is arbitrary but ensures equal ordering on repeated
calls. Within the set of features for a given hit-sequence-accession,
features are considered in decreasing order of score.

Coverage filtering is conservative in that it keeps all features for
a hit-sequence-accession unless all features for that
hit-sequence-accession are covered too deeply. If there is but one
feature that isn't covered too deeply, this will save all features
for the hit-sequence-accession. Hence coverage filtering does not
provide a hard limit on the depth of coverage.

The option prune is off by default. If on, it allows only a maximum
number of features per strand per genomic base per hit sequence
accession, this number also being specified by the coverage parameter.
Prune works on a per-hit-sequence-accession basis and removes features
(not entire hit-sequence-accessions) until the criterion is met for
each hit-sequence-accession. Prune filtering occurs after coverage
filtering. It provides a hard limit on the depth of coverage by
each hit-sequence-accession, but does not prevent deep overall
coverage by many different hit-sequence-accessions.

The option hardprune is off by default. If on, allows only a maximum
number of features per strand per genomic base, this number also being
specified by the coverage parameter. Hard pruning is achieved by a
prune-like step in which all features are considered together,
irrespective of hit-sequence-accession. This is more severe than
the above prune step and provides a hard limit on the depth of
coverage of genomic sequence. Hardprune can be performed with or
without prune. The hardprune step is the final stage of filtering.'

=head1 CONTACT

Ensembl - ensembl-dev@ebi.ac.uk

=head1 APPENDIX

The rest of the documentation details each of the object methods.
Internal methods are usually preceded with a _
'
=cut

# Let the code begin...


package Bio::EnsEMBL::Pipeline::Runnable::FeatureFilter;
use vars qw(@ISA);
use strict;
use Bio::EnsEMBL::Utils::Exception qw(verbose throw warning info);
use Bio::EnsEMBL::Utils::Argument qw( rearrange );
# Object preamble - inherits from Bio::EnsEMBL::Pipeline::RunnableI;

use Bio::EnsEMBL::Pipeline::RunnableI;


@ISA = qw(Bio::EnsEMBL::Pipeline::RunnableI);

sub new {
  my($class,@args) = @_;

  my $self = $class->SUPER::new(@args);  

  my($minscore,$maxevalue,$coverage,$prune, $hardprune) = rearrange(
                                                                [qw(MINSCORE
								    MAXEVALUE
								    COVERAGE
								    PRUNE
								    HARDPRUNE
							           )], @args);

  $minscore  = -100000 unless $minscore;
  $maxevalue = 0.1     unless $maxevalue;
  $coverage  = 10      unless $coverage;
  $prune     = 0       unless $prune;
  $hardprune = 0       unless $hardprune;

  $self->minscore($minscore);
  $self->maxevalue($maxevalue);
  $self->coverage($coverage);
  $self->prune($prune);
  $self->hardprune($hardprune);
  
  return $self;
}


=head2 run

 Title   : run
 Usage   : my @filteredfeatures = $search->run(@features);
 Function: filter Blast or other search results
 Returns : array of featurepairs
 Args    : array of featurepairs


=cut

sub run{
  my ($self,@input) = @_;
  #print STDERR "Have ".@input." features to filter\n";
  my ($minscore,$maxevalue,$coverage);
  my $starts = 0;
  my $ends = 0;
  $minscore  = $self->minscore;
  $maxevalue = $self->maxevalue;
  $coverage  = $self->coverage;
  my %validhit;
  my %hitarray;
  
  # first- scan across all features, considering
  # valid to be > minscore < maxevalue
  
  my $maxend = 0;
  my %totalscore;     # total score per hid
  
  # All featurepairs have a score. 
  # Some may have an evalue.
  
  # valid hits are stored in a hash of arrays
  # we sort by score to know that the first score for a hseqname is its best  
  @input = sort { $b->score <=> $a->score } @input;
  ##print STDERR "Have ".@input." features to filter\n";
  foreach my $f ( @input ) {

    if( $f->score > $minscore ) {
      
      unless ( $validhit{$f->hseqname} ) {
	$validhit{$f->hseqname} = 0;
	$totalscore{$f->hseqname} = 0;
      }

      $totalscore{$f->hseqname} += $f->score;
      
      if( $f->can('evalue') && defined $f->evalue ) {
	if( $f->evalue < $maxevalue ) {
	  
	  if( $validhit{$f->hseqname} < $f->score ) {
	    $validhit{$f->hseqname} = $f->score;
	  }
	  if( $f->end > $maxend ) {
	    $maxend = $f->end;
	  }
	}
      }

      else {
	if( $validhit{$f->hseqname} < $f->score ) {
	  $validhit{$f->hseqname} = $f->score;
	}
	if( $f->end > $maxend ) {
	  $maxend = $f->end;
	}
      }
    }
    
    # regardless of score, take if this hseqname is valid
    if( $validhit{$f->hseqname} ) {
      if( ! exists $hitarray{$f->hseqname} ) {
	$hitarray{$f->hseqname} = [];
      }
      push(@{$hitarray{$f->hseqname}},$f);
    }
    
  }
  my $total_count = 0;
  foreach my $id(keys(%hitarray)){
    $total_count += @{$hitarray{$id}};
  }
  #print STDERR "After filtering on score have ".$total_count." features ".
    " on ".keys(%hitarray)." hit ids\n";
  @input = ();	# free some memory?
  
  # sort the HID list by highest score per feature, then by highest
  # total score, and alphabetically as a last resort
  my @inputids = sort {    $validhit{$b}   <=> $validhit{$a}
                        or $totalscore{$b} <=> $totalscore{$a}
			or $a cmp $b
		      } keys %validhit;
  
  # This will hold the accepted HIDs for both strands.
  # Hash not array to avoid duplication if same HID accepted on both
  # strands, but the keys (HIDs) are the only important part.
  my %accepted_hids;

  my @strands = ( +1, -1 );
  my %coverage_skip;
  foreach my $strand (@strands) {

    # coverage vector, Perl will automatically extend this array
    my @list;
    $list[$maxend] = 0;
 
    # we accept all feature pairs which are: (1) on the strand being
    # considered, (2) valid, and (3) meet coverage criteria
    ##print STDERR "Coverage is ".$coverage."\n";
    FEATURE :
    foreach my $hseqname ( @inputids ) {
      #my ($name) = $hseqname =~ /(\w+)\s+\w+/;
      #print $name."\n";
      my $hole = 0;

      foreach my $f ( @{$hitarray{$hseqname}} ) {
        
        next if $f->strand != $strand;
        
        # only mark if this feature is valid
        if( (($f->score > $minscore) || ($f->can('evalue'))
             && defined $f->evalue && $f->evalue < $maxevalue ) ){
          for my $i ( $f->start .. $f->end ) {
            unless( $list[$i] ){
              $list[$i] = 0;
            }
            if( $list[$i] < $coverage ) {
              # accept!
              $hole = 1;
              last;
            }
          }
        }
      }
    
      if( $hole == 0 ) { 
        if(!$accepted_hids{$hseqname}){
          $coverage_skip{$hseqname} = 1;
        }
        my ($name) = $hseqname =~ /(\w+)\s+\w+/;
        #print STDERR "Skipping ".$name."\n";
        # all f's for HID completely covered at a depth >= $coverage
        next;
      }
      
      $accepted_hids{$hseqname} = 1;
      foreach my $f ( @{$hitarray{$hseqname}} ) {
        
        if ($f->strand == $strand) {
          for my $i ( $f->start .. $f->end ) {
            $list[$i]++; 
          }
        }
      }
    }
  }
  my $skipped = 0;
  foreach my $name(keys(%coverage_skip)){
    if(!$accepted_hids{$name}){
      $skipped++;
    }
  }
  ##print STDERR "have skipped ".$skipped." ids entirely\n";
  $total_count = 0;
  foreach my $id(keys(%accepted_hids)){
    $total_count += @{$hitarray{$id}};
  }
  #print STDERR "After filtering on coverage have ".$total_count.
    " features on ".keys(%accepted_hids)." hit ids\n";
  my @accepted_features = ();
  if ($self->prune) {
    foreach my $hid ( keys %accepted_hids ) {
      $starts += @{$hitarray{$hid}};
      my @tmp = $self->prune_features(@{$hitarray{$hid}});
      $ends += @tmp;
      push(@accepted_features, @tmp);
    }
  } else {
    foreach my $hid ( keys %accepted_hids ) {
      push(@accepted_features, @{$hitarray{$hid}} );
    }
  }

  # free some memory?
  %accepted_hids = ();
  %hitarray = ();

  if ($self->hardprune) {
    # prune all together taking the first '$self->coverage' according to score 
    @accepted_features = $self->prune_features( @accepted_features );
  }
  ##print STDERR "Started with ".$starts." features. Filtering left ".$ends.
  #  " features\n";
  my %hit_ids;
  foreach my $f(@accepted_features){
    if(!$hit_ids{$f->hseqname}){
      $hit_ids{$f->hseqname} = 1;
    }
  }
  #print STDERR "Returning ".@accepted_features." after prune across ".
  #keys(%hit_ids)." hit ids\n";
  
  return @accepted_features;
    
  1;
}

=head2 hardprune

 Title   : hardprune
 Usage   : $obj->hardprune(0);
 Function: 
 Returns : value of hardprune
 Args    : newvalue (optional), nonzero for 'on'


=cut

sub hardprune {
  my ($self,$arg) = @_;

  if (defined($arg)) {
    $self->{_hardprune} = $arg;
  }
  return $self->{_hardprune};
}

=head2 prune

 Title   : prune
 Usage   : $obj->prune(1);
 Function: 
 Returns : value of prune
 Args    : newvalue (optional), nonzero for 'on'

=cut

sub prune {
  my ($self,$arg) = @_;

  if (defined($arg)) {
    $self->{_prune} = $arg;
  }
  return $self->{_prune};
}

=head2 prune_features

 Title   : prune_features
 Usage   : @pruned_fs = $self->prune_features(@f_array);
 Function: reduce coverage of each base to a maximum of
           $self->coverage features on each strand, by
	   removing low-scoring features as necessary.
 Returns : array of features
 Args    : array of features'

=cut

sub prune_features {
  my ($self, @input) = @_;
  throw('interface fault') if @_ < 1;	# @input optional
  #print STDERR "Prune:Have ".@input." features to prune\n";
  my @plus_strand_fs = $self->_prune_features_by_strand(+1, @input);
  my @minus_strand_fs = $self->_prune_features_by_strand(-1, @input);
  @input = ();
  push @input, @plus_strand_fs;
  push @input, @minus_strand_fs;
  #print STDERR "Prune:Have ".@input." features to return\n";
  return @input;
}

=head2 _prune_features_by_strand

 Title   : _prune_features_by_strand
 Usage   : @pruned_neg = $self->prune_features(-1, @f_array);
 Function: reduce coverage of each genomic base to a maximum of
           $self->coverage features on the specified strand;
	   all features not on the specified strand are discarded
 Returns : array of features
 Args    : strand, array of features

=cut

sub _prune_features_by_strand {
   my ($self, $strand, @in) = @_;
   throw('interface fault') if @_ < 2;	# @in optional

   my @input_for_strand = ();
   foreach my $f (@in) {
     push @input_for_strand, $f if $f->strand eq $strand;
   }

   return () if !@input_for_strand;

   # get the genomic first and last bases covered by any features
   my @sorted_fs = sort{ $a->start <=> $b->start } @input_for_strand;
   my $first_base = $sorted_fs[0]->start;
   @sorted_fs = sort{ $a->end <=> $b->end } @input_for_strand;
   my $last_base = $sorted_fs[$#sorted_fs]->end;

   # fs_per_base: set element i to the number of features covering base i
   my @fs_per_base = ();
   foreach  my $base ($first_base..$last_base) {
     $fs_per_base[$base] = 0;	# initialise
   }
   foreach my $f (@input_for_strand) {
     foreach my $covered_base ($f->start..$f->end) {
       $fs_per_base[$covered_base]++;
     }
   }

   # put the worst features first, so they get removed with priority
   @sorted_fs = sort { $a->score <=> $b->score } @input_for_strand;

   @input_for_strand = ();	# free some memory?

   # over_covered_bases: list of base numbers where coverage must be
   # reduced, listed worst-case-first
   my $max_coverage = $self->coverage;
   my @over_covered_bases = ();
   foreach my $base ($first_base..$last_base) {
     my $excess_fs = $fs_per_base[$base] - $max_coverage;
     if ($excess_fs > 0) {
       push @over_covered_bases, $base;
     }
   }
   @over_covered_bases = sort { $fs_per_base[$b] <=> $fs_per_base[$a] }
     @over_covered_bases;

   foreach my $base (@over_covered_bases) {
     my $f_no = 0;
     while ($fs_per_base[$base] > $max_coverage) {
       my $start = $sorted_fs[$f_no]->start;
       my $end = $sorted_fs[$f_no]->end;
       if ($start <= $base and $end >= $base) {	# cut this feature
         splice @sorted_fs, $f_no, 1;	# same index will give next feature
         foreach my $was_covered ($start..$end) {
           $fs_per_base[$was_covered]--;
         }
       } else {	# didn't overlap this base, move on to next feature
         $f_no++;
       }
     }
   }
   return @sorted_fs;
}

=head2 minscore

 Title   : minscore
 Usage   : $obj->minscore($newval)
 Function: 
 Returns : value of minscore
 Args    : newvalue (optional)


=cut

sub minscore{
   my $obj = shift;
   if( @_ ) {
      my $value = shift;
      $obj->{'minscore'} = $value;
    }
    return $obj->{'minscore'};

}

=head2 maxevalue

 Title   : maxevalue
 Usage   : $obj->maxevalue($newval)
 Function: 
 Returns : value of maxevalue
 Args    : newvalue (optional)


=cut

sub maxevalue{
   my $obj = shift;
   if( @_ ) {
      my $value = shift;
      $obj->{'maxevalue'} = $value;
    }
    return $obj->{'maxevalue'};

}

=head2 coverage

 Title   : coverage
 Usage   : $obj->coverage($newval)
 Function: 
 Returns : value of coverage
 Args    : newvalue (optional)


=cut

sub coverage{
   my $obj = shift;
   if( @_ ) {
      my $value = shift;
      $obj->{'coverage'} = $value;
    }
    return $obj->{'coverage'};

}
1;

