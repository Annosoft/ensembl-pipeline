#
# You may distribute this module under the same terms as perl itself
#
# POD documentation - main docs before the code

=pod 

=head1 NAME

Bio::EnsEMBL::Pipeline::RunnableDB

=head1 SYNOPSIS

# get a Bio::EnsEMBL::Pipeline::RunnableDB pbject somehow

  $runnabledb->fetch_input();
  $runnabledb->run();
  $runnabledb->output();
  $runnabledb->write_output(); #writes to DB

=head1 DESCRIPTION

This is the base implementation of
This object encapsulates the basic main methods of a RunnableDB
which a subclass may override.

parameters to new
-db:        A Bio::EnsEMBL::DBSQL::DBAdaptor (required), 
-input_id:   Contig input id (required), 
-analysis:  A Bio::EnsEMBL::Analysis (optional) 

This object wraps Bio::EnsEMBL::Pipeline::Runnable to add
functionality for reading and writing to databases.  The appropriate
Bio::EnsEMBL::Analysis object must be passed for extraction
of appropriate parameters. A Bio::EnsEMBL::Pipeline::DBSQL::DBAdaptor is
required for databse access.

=head1 CONTACT

ensembl-dev@ebi.ac.uk

=head1 APPENDIX

The rest of the documentation details each of the object methods. 
Internal methods are usually preceded with a _

=cut

package Bio::EnsEMBL::Pipeline::RunnableDB;

use strict;
use Bio::EnsEMBL::Pipeline::SeqFetcher;
use Bio::EnsEMBL::Pipeline::SeqFetcher::Pfetch;
use Bio::EnsEMBL::Pipeline::RunnableI;
use Bio::EnsEMBL::Utils::Exception qw(verbose throw warning);
use Bio::EnsEMBL::Utils::Argument qw(rearrange);
use Bio::DB::RandomAccessI;

use vars qw(@ISA);

@ISA = qw(Bio::EnsEMBL::Pipeline::RunnableI);

=head2 new

    Title   :   new
    Usage   :   $self->new(-DB          => $db,
                           -INPUT_ID    => $id,
                           -SEQFETCHER  => $sf,
			   -ANALYSIS    => $analysis);

    Function:   creates a Bio::EnsEMBL::Pipeline::RunnableDB object
    Returns :   A Bio::EnsEMBL::Pipeline::RunnableDB object
    Args    :   -db:         A Bio::EnsEMBL::DBSQL::DBAdaptor (required), 
                -input_id:   Contig input id (required), 
                -seqfetcher: A Bio::DB::RandomAccessI Object (required),
                -analysis:   A Bio::EnsEMBL::Analysis (optional) 
=cut

sub new {
    my ($class, @args) = @_;

    my $self = {};
    bless $self, $class;

    my ($db,
        $input_id, 
        $seqfetcher, 
        $analysis) = &rearrange([qw(DB
				    INPUT_ID
				    SEQFETCHER
			     	    ANALYSIS )], @args);


    $self->{'_genseq'}      = undef;
    $self->{'_runnable'}    = undef;
    $self->{'_parameters'}  = undef;
    $self->{'_analysis'}    = undef;

    &throw("No database handle input") unless defined($db);
    $self->db($db);

    &throw("No input id input")        unless defined($input_id);
    $self->input_id($input_id);

    # we can't just default this to pfetch
    $seqfetcher && $self->seqfetcher($seqfetcher);

    &throw("No analysis object input") unless defined($analysis);
    $self->analysis($analysis);
    &verbose('EXCEPTION');
    return $self;
}

=head2 analysis

    Title   :   analysis
    Usage   :   $self->analysis($analysis);
    Function:   Gets or sets the stored Analusis object
    Returns :   Bio::EnsEMBL::Analysis object
    Args    :   Bio::EnsEMBL::Analysis object

=cut

sub analysis {
    my ($self, $analysis) = @_;
    
    if ($analysis) {
        &throw("Not a Bio::EnsEMBL::Analysis object")
            unless ($analysis->isa("Bio::EnsEMBL::Analysis"));
        $self->{'_analysis'} = $analysis;
        $self->parameters($analysis->parameters);
    }
    return $self->{'_analysis'};
}

=head2 parameters

    Title   :   parameters
    Usage   :   $self->parameters($param);
    Function:   Gets or sets the value of parameters
    Returns :   A string containing parameters for Bio::EnsEMBL::Runnable run
    Args    :   A string containing parameters for Bio::EnsEMBL::Runnable run

=cut

sub parameters {
    my ($self, $parameters) = @_;

    $self->analysis->parameters($parameters) if ($parameters);


    return $self->analysis->parameters();
}

sub arguments {
  my ($self) = @_;

  my %parameters = $self->parameter_hash;

  my $options = "";

  foreach my $key (keys %parameters) {
    if ($parameters{$key} ne "__NONE__") {
      $options .= " " . $key . " " . $parameters{$key};
    } else {
      $options .= " " . $key;
    }
  }
  return $options;
}

=head2 parameter_hash

 Title   : parameter_hash
 Usage   :
 Function:
 Example :
 Returns : 
 Args    :


=cut

sub parameter_hash{
   my ($self,@args) = @_;

    my ($parameter_string) = $self->analysis->parameters() ;

    my %parameters;

    if ($parameter_string) {

      my @pairs = split (/,/, $parameter_string);
      foreach my $pair (@pairs) {
	
	my ($key, $value) = split (/=>/, $pair);

	if (defined($key) && defined($value)) {
	  $key   =~ s/^\s+//g;
	  $key   =~ s/\s+$//g;
	  $value =~ s/^\s+//g;
	  $value =~ s/\s+$//g;
	  
	  $parameters{$key} = $value;
	} else {
          $parameters{$key} = "__NONE__";
	}
      }
    }
    return %parameters;
}

=head2 db

    Title   :   db
    Usage   :   $self->db($obj);
    Function:   Gets or sets the value of db
    Returns :   A Bio::EnsEMBL::Pipeline::DBSQL::DBAdaptor compliant object
                (which extends Bio::EnsEMBL::DBSQL::DBAdaptor)
    Args    :   A Bio::EnsEMBL::Pipeline::DBSQL::DBAdaptor compliant object

=cut

sub db {
    my( $self, $value ) = @_;

    if ($value) {
       $value->isa("Bio::EnsEMBL::DBSQL::DBAdaptor")
         || &throw("Input [$value] isn't a Bio::EnsEMBL::DBSQL::DBAdaptor");

       $self->{'_db'} = $value;
    }
    return $self->{'_db'};
}

=head2 input_id

    Title   :   input_id
    Usage   :   $self->input_id($input_id);
    Function:   Gets or sets the value of input_id
    Returns :   valid input id for this analysis (if set) 
    Args    :   input id for this analysis 

=cut

sub input_id {
    my ($self, $input) = @_;

    if ($input) {
        $self->{'_input_id'} = $input;
    }

    return $self->{'_input_id'};
}

=head2 query

    Title   :   query
    Usage   :   $self->query($query);
    Function:   Get/set query
    Returns :   
    Args    :   

=cut

sub query {
    my ($self, $query) = @_;

    if (defined($query)){ 
	$self->{'_query'} = $query; 
    }

    return $self->{'_query'}
}

=head2 output

    Title   :   output
    Usage   :   $self->output()
    Function:   
    Returns :   Array of Bio::EnsEMBL::FeaturePair
    Args    :   None

=cut

sub output {
    my ($self) = @_;
   
    $self->{'_output'} = [];
    
    my @r = $self->runnable;

    if(@r && scalar(@r)){
      foreach my $r ($self->runnable){
        push(@{$self->{'_output'}}, $r->output);
      }
    }
    return @{$self->{'_output'}};
}

=head2 run

    Title   :   run
    Usage   :   $self->run();
    Function:   Runs Bio::EnsEMBL::Pipeline::Runnable::xxxx->run()
    Returns :   none
    Args    :   none

=cut

sub run {
    my ($self) = @_;

    foreach my $runnable ($self->runnable) {

      &throw("Runnable module not set") unless ($runnable);

      # Not sure about this
      &throw("Input not fetched")       unless ($self->query);

      $runnable->run();
    }
    return 1;
}

=head2 runnable

    Title   :   runnable
    Usage   :   $self->runnable($arg)
    Function:   Sets a runnable for this RunnableDB
    Returns :   Bio::EnsEMBL::Pipeline::RunnableI
    Args    :   Bio::EnsEMBL::Pipeline::RunnableI

=cut

sub runnable {
  my ($self,$arg) = @_;

  if (!defined($self->{'_runnables'})) {
      $self->{'_runnables'} = [];
  }
  
  if (defined($arg)) {

      if ($arg->isa("Bio::EnsEMBL::Pipeline::RunnableI")) {
	  push(@{$self->{'_runnables'}},$arg);
      } else {
	  &throw("[$arg] is not a Bio::EnsEMBL::Pipeline::RunnableI");
      }
  }
  
  return @{$self->{'_runnables'}};  
}


=head2 write_output

    Title   :   write_output
    Usage   :   $self->write_output
    Function:   Writes output data to db
    Returns :   array of repeats (with start and end)
    Args    :   none

=cut

sub write_output {
    my ($self) = @_;

    my $db       = $self->db();
    my @features = $self->output();
    my $contig;
    print STDERR "Write output have ".@features." features\n";
    my $sim_adp  = $self->db->get_SimpleFeatureAdaptor;
    my $mf_adp   = $self->db->get_MarkerFeatureAdaptor;
    my $pred_adp = $self->db->get_PredictionTranscriptAdaptor;
    my $dna_adp  = $self->db->get_DnaAlignFeatureAdaptor;
    my $rept_adp = $self->db->get_RepeatFeatureAdaptor;
    my $pep_adp  = $self->db->get_ProteinAlignFeatureAdaptor;
    my $gene_adp = $self->db->get_GeneAdaptor;




    eval {
      $contig = $db->get_SliceAdaptor->fetch_by_name($self->input_id);
    };

    if ($@) {
      &throw("Can't find contig " . $self->input_id . " . Can't write output");
    }
  
    my %features;

    foreach my $f (@features) {

      $f->analysis($self->analysis);

      unless ($f->isa("Bio::EnsEMBL::PredictionTranscript")) {
        $f->slice($contig);
      }

      if ($f->isa("Bio::EnsEMBL::PredictionTranscript")) {
        foreach my $exon (@{$f->get_all_Exons}) {
          $exon->slice($contig);
        }

        if (!defined($features{prediction})) {
          $features{prediction} = [];
        }
        
        push(@{$features{prediction}},$f);
        
        
      } elsif ($f->isa("Bio::EnsEMBL::SimpleFeature")) {
        
        if (!defined($features{simple})) {
          $features{simple} = [];
        }
        
        push(@{$features{simple}},$f);
        
      } elsif ($f->isa("Bio::EnsEMBL::Map::MarkerFeature")) {
        
        if (!defined($features{marker})) {
          $features{marker} = [];
        }
        
        push(@{$features{marker}},$f);
        
      } elsif ($f->isa("Bio::EnsEMBL::DnaPepAlignFeature")) {
        
        if (!defined($features{dnapep})) {
          $features{dnapep} = [];
        }

        push(@{$features{dnapep}},$f);
        
      } elsif ($f->isa("Bio::EnsEMBL::DnaDnaAlignFeature")) {
        
        if (!defined($features{dnadna})) {
          $features{dnadna} = [];
        }
        
        push(@{$features{dnadna}},$f);
        
      } elsif ($f->isa("Bio::EnsEMBL::RepeatFeature")) {
        
        if (!defined($features{repeat})) {
          $features{repeat} = [];
        }
        
        push(@{$features{repeat}},$f);
        
      } elsif ($f->isa("Bio::EnsEMBL:Gene")) {
        
        foreach my $exon (@{$f->get_all_Exons}) {
          $exon->slice($contig);
        }
        if (!defined($features{gene})) {
          $features{gene} = [];
        }
        
        push(@{$features{gene}},$f);
        
      }
    }
    
    if ($features{prediction}) {
      $pred_adp->store(@{$features{prediction}});
      print "Storing " . @{$features{prediction}} . "\n";
    }
    if ($features{simple}) {
      $sim_adp->store(@{$features{simple}});
    }
    if ($features{marker}) {
      $mf_adp->store(@{$features{marker}});
    }
    if ($features{dnadna}) {
      $dna_adp->store(@{$features{dnadna}});
    }
    if ($features{dnapep}) {
      $pep_adp->store(@{$features{dnapep}});
    }
    if ($features{repeat}) {
      $rept_adp->store(@{$features{repeat}});
    }
    if ($features{gene}) {
      $gene_adp->store(@{$features{gene}});
    }

    return 1;
}

=head2 seqfetcher

    Title   :   seqfetcher
    Usage   :   $self->seqfetcher($seqfetcher)
    Function:   Get/set method for SeqFetcher
    Returns :   Bio::DB::RandomAccessI object
    Args    :   Bio::DB::RandomAccessI object

=cut

sub seqfetcher {
  my( $self, $value ) = @_;    

  if (defined($value)) {

    $self->{'_seqfetcher'} = $value;
  }
    return $self->{'_seqfetcher'};
}

=head2 input_is_void

    Title   :   input_is_void
    Usage   :   $self->input_is_void(1)
    Function:   Get/set flag for sanity of input sequence
                e.g. reject seqs with only two base pairs
    Returns :   Boolean
    Args    :   Boolean

=cut

sub input_is_void {
    my ($self, $value) = @_;

    if ($value) {
	$self->{'_input_is_void'} = $value;
    }
    return $self->{'_input_is_void'};

}


=head failiing_job_status

    Title   :  failing_job_status
    Useage  :  $self->failing_job_status('OUT OF MEMORY');
    Function:  Get/Set a status message to go into the job_status
               table of the pipeline.  
    Returns :  String or undef
               N.B. currently only 40 chars are stored in db
    Args    :  String
               N.B. currently only 40 chars are stored in db
    Caller  :  Bio::EnsEMBL::Pipeline::Job::run_module()
    Why     :  Because neither the runnable nor the runnabledb have
               enough information to do $job_adap->set_status($job)

               i.e. no jobID. to get a job from the adaptor.

               Ok it could get it using fetch_by_input_id looping through
               that list until it find the right one. that gets alot of 
               useless data from the db.  They probably shouldn\'t be doing
               that anyway.  So this lets the Job->run_module do it when
               and if the RunnableDB::xyz->run populates $@ (throws/dies)
    Example :  See RunnableDB::Finished_Blast::run

=cut

sub failing_job_status{
    my ($self, $error) = @_;
    $self->{'_error_status'} = $error if $error;
    #return ($@ ? $self->{'_error_status'} : undef); # not convinced this was sensible
    return $self->{'_error_status'};
}


=head fetch_sequence

    Title   :  failing_job_status
    Useage  :  $self->fetch_sequence
    Function:  fetch a slice out of a specified database  
    Returns :  Bio::EnsEMBL::Slice, which is also placed in $self->query
    Args    :  array ref, to an array specifying what repeats are to be masked
               if any. If there is no ref no repeats with be masked if the 
               array exists but is empty e.g [''] all repeats will be masked
               if the array has entries repeats of those logic_names will be
               masked e.g ['RepeatMask']
               Bio::EnsEMBL::DBAdaptor to allow slices to be fetched from 
               a database not specified by $self->db
    Caller  :  Bio::EnsEMBL::Pipeline::RunnableDB::module->fetch_input
    Why     :  In this schema sequence is always fetched in the same way
               provided the name matched the format specified in 
               Bio::EnsEMBL::Slice::name 
    Example :  See RunnableDB::Blast::fetch_input

=cut

sub fetch_sequence{
  my ($self, $repeat_masking, $db) = @_;

  if(!$db){
    $db = $self->db;
  }
  #print STDERR "Fetching sequence from ".$self->db->dbname."\n";
  my $sa = $db->get_SliceAdaptor;
#print STDERR "Have input_id ".$self->input_id."\n";
  my $slice = $sa->fetch_by_name($self->input_id);
  $repeat_masking = [] unless($repeat_masking);
  if(@$repeat_masking){
    my $sequence = $slice->get_repeatmasked_seq($repeat_masking);
    $self->query($sequence);
  }else{
    $self->query($slice);
  }
  #print STDERR "have sequence ".$self->query."\n";
  return $self->query;
}

1;
