# Author: Marc Sohrmann (ms2@sanger.ac.uk)
# Copyright (c) Marc Sohrmann, 2001
# You may distribute this code under the same terms as perl itself
#
# You may distribute this module under the same terms as perl itself
#
# POD documentation - main docs before the code

=pod 

=head1 NAME

  Bio::EnsEMBL::Pipeline::RunnableDB::Protein::Signalp

=head1 SYNOPSIS

  my $signalp = Bio::EnsEMBL::Pipeline::RunnableDB::Protein::Signalp->new ( -dbobj      => $db,
    	  	                                                            -input_id   => $input_id,
                                                                            -analysis   => $analysis,
                                                                          );
  $signalp->fetch_input;  # gets sequence from DB
  $signalp->run;
  $signalp->output;
  $signalp->write_output; # writes features to to DB

=head1 DESCRIPTION

  This object wraps Bio::EnsEMBL::Pipeline::Runnable::Protein::Signalp
  to add functionality to read and write to databases.
  A Bio::EnsEMBL::Pipeline::DBSQL::DBAdaptor is required for database access (dbobj).
  The query sequence is provided through the input_id.
  The appropriate Bio::EnsEMBL::Pipeline::Analysis object
  must be passed for extraction of parameters.

=head1 CONTACT

  Marc Sohrmann: ms2@sanger.ac.uk

=head1 APPENDIX

  The rest of the documentation details each of the object methods. 
  Internal methods are usually preceded with a _.

=cut

package Bio::EnsEMBL::Pipeline::RunnableDB::Protein::Signalp;

use strict;
use vars qw(@ISA);

use Bio::EnsEMBL::Pipeline::RunnableDB;
use Bio::EnsEMBL::Pipeline::Runnable::Protein::Signalp;
use Bio::EnsEMBL::DBSQL::Protein_Feature_Adaptor;

@ISA = qw(Bio::EnsEMBL::Pipeline::RunnableDB);


=head2 new

 Title    : new
 Usage    : $self->new ( -dbobj       => $db
                         input_id    => $id
                         -analysis    => $analysis,
                       );
 Function : creates a Bio::EnsEMBL::Pipeline::RunnableDB::Protein::Signalp object
 Example  : 
 Returns  : a Bio::EnsEMBL::Pipeline::RunnableDB::Protein::Signalp object
 Args     : -dbobj    :  a Bio::EnsEMBL::Pipeline::DBSQL::DBAdaptor
            -input_id :  input id
            -analysis :  a Bio::EnsEMBL::Pipeline::Analysis
 Throws   :

=cut

sub new {
    my ($class, @args) = @_;

    # this new method also parses the @args arguments,
    # and verifies that -dbobj and -input_id have been assigned
    my $self = $class->SUPER::new(@args);
    $self->throw ("Analysis object required") unless ($self->analysis);
    $self->{'_genseq'}      = undef;
    $self->{'_runnable'}    = undef;
    
    # set up signalp specific parameters,
    # my $params = $self->parameters;  # we don't have to read the parameters column from the database
                                       # in this case; no parameters are passed on to the Runnable 

#    my $params;
#    if ($params ne "") { $params .= ","; }
    # get the path to the binaries from the Analysis object (analysisprocess table)
#    $params .= "-analysis=>".$self->analysis."\n";

#    print STDERR "PROGR0: ".$self->analysis->program."\n";
    #$params .= "-program=>".$self->analysis->program.",";
    # get the analysisId from the Analysis object (analysisprocess table)
    #$params .= "-analysisid=>".$self->analysis->dbID;
    
#    $self->parameters($params);

#    $self->runnable('Bio::EnsEMBL::Pipeline::Runnable::Protein::Signalp');
    return $self;
}


sub runnable {
    my ($self) = @_;
    
    if (!defined($self->{'_runnable'})) {
	print STDERR "CLONE: ".$self->genseq."\n";
	my $run = Bio::EnsEMBL::Pipeline::Runnable::Protein::Signalp->new(-clone     => $self->genseq,
									-analysis  => $self->analysis	);
 
           
      $self->{'_runnable'} = $run;
    }
    
    return $self->{'_runnable'};
}

=head2 run

    Title   :   run
    Usage   :   $self->run();
    Function:   Runs Bio::EnsEMBL::Pipeline::Runnable::Protein::Profile->run()
    Returns :   none
    Args    :   none

=cut

sub run {
    my ($self,$dir) = @_;
    $self->throw("Runnable module not set") unless ($self->runnable());
    $self->throw("Input not fetched")      unless ($self->genseq());

    $self->runnable->run($dir);
}



# IO methods

=head2 fetch_input

 Title    : fetch_input
 Usage    : $self->fetch_input
 Function : fetches the query sequence from the database
 Example  :
 Returns  :
 Args     :
 Throws   :

=cut

sub fetch_input {
    my ($self) = @_;
    my $proteinAdaptor = $self->dbobj->get_Protein_Adaptor;
    my $prot;
    my $peptide;

    eval {
	$prot = $proteinAdaptor->fetch_Protein_by_dbid ($self->input_id);
    };
    
    if (!$@) {
	#The id is a protein id, that's fine, create a PrimarySeq object
	my $pepseq    = $prot->seq;
	$peptide  =  Bio::PrimarySeq->new(  '-seq'         => $pepseq,
					    '-id'          => $self->input_id,
					    '-accession'   => $self->input_id,
					    '-moltype'     => 'protein');
    }

    else {
	#An error has been returned...2 solution, either the input is a peptide file and we can go on or its completly rubish and we throw an exeption.
	
	
	#Check if the file exists, if not throw an exeption 
	$self->throw ("The input_id given is neither a protein id nor an existing file") unless (-e $self->input_id);
	$peptide = $self->input_id;
    }

    
    $self->genseq($peptide);
}


=head2 write_output

 Title    : write_output
 Usage    : $self->write_output
 Function : writes the features to the database
 Example  :
 Returns  :
 Args     :
 Throws   :

=cut

sub write_output {
    my ($self) = @_;
    my $proteinFeatureAdaptor = $self->dbobj->get_Protfeat_Adaptor;;
    my @featurepairs = $self->output;

    foreach my $feat(@featurepairs) {
	$proteinFeatureAdaptor->write_Protein_feature($feat);
    }

    #$proteinFeatureAdaptor->store (@featurepairs);
}


# runnable method



1;
