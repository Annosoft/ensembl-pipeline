# Perl module for Bio::EnsEMBL::Pipeline::DBSQL::StateInfoContainer
#
# Creator: Arne Stabenau <stabenau@ebi.ac.uk>
#
# Date of creation: 15.09.2000
# Last modified : 20.09.2000 by Arne Stabenau
#
# Copyright EMBL-EBI 2000
#
# You may distribute this module under the same terms as perl itself

# POD documentation - main docs before the code

=head1 NAME

Bio::EnsEMBL::Pipeline::DBSQL::StateInfoContainer

=head1 SYNOPSIS

  $infoContainer = $dbobj->get_StateInfoContainer;


=head1 DESCRIPTION

  Module which encapsulates state request for objects in the database.
  Starts of with a table InputIdAnalysis, providing which analysis was done to
  inputIds but every state information access should go via this object.

  Deliberatly NOT called an adaptor, as it does not serve obejcts.

=head1 CONTACT

    Contact Arne Stabenau on implemetation/design detail: stabenau@ebi.ac.uk
    Contact Ewan Birney on EnsEMBL in general: birney@sanger.ac.uk

=head1 APPENDIX

The rest of the documentation details each of the object methods. Internal methods are usually preceded with a _

=cut


# Let the code begin...


package Bio::EnsEMBL::Pipeline::DBSQL::StateInfoContainer;

use Bio::EnsEMBL::Pipeline::DBSQL::AnalysisAdaptor;
use vars qw(@ISA);
use strict;


@ISA = qw( Bio::Root::RootI );

sub new {
  my $class = shift;
  my $self = bless( {}, $class);

  my $dbobj = shift;

  $self->db( $dbobj );
  return $self;
}

sub fetch_analysis_by_inputId_class {
  my $self = shift;
  my $inputId = shift;
  my $class = shift;
  my @result;
  my @row;

  my $anaAd = $self->db->get_AnalysisAdaptor;

  my $sth = $self->prepare( q {
    SELECT analysisId
      FROM InputIdAnalysis
     WHERE inputId = ?
       AND class = ? } );
  $sth->execute( $inputId, $class );

  while( my @row = $sth->fetchrow_array ) {
    my $analysis = $anaAd->fetch_by_dbID( $row[0] );
    if( defined $analysis ) {
      push( @result, $analysis );
    }
  }

  return @result;
}

sub store_inputId_class_analysis {
  my ( $self, $inputId, $class, $analysis ) = @_;

  my $sth = $self->prepare( qq{
    INSERT INTO InputIdAnalysis values (
          '$inputId',
          '$class',
          ?,
          now() )} );
#    INSERT INTO InputIdAnalysis
#      SET inputId='$inputId',
#          class='$class',
#          created = now(),
#          analysisId = ? } );
  $sth->execute( $analysis->dbID );
}

sub list_inputId_by_analysis {
  my $self = shift;
  my $analysis = shift;
  my @result;
  my @row;

  my $sth = $self->prepare( q {
    SELECT inputId
      FROM InputIdAnalysis
     WHERE analysisId = ? } );
  $sth->execute( $analysis->dbID );

  while( @row = $sth->fetchrow_array ) {
    push( @result, $row[0] );
  }

  return @result;
}

sub list_inputId_class_by_start_count {
  my $self = shift;
  my ($start,$count) = @_;
  my @result;
  my @row;

  my $query = qq{
    SELECT inputId, class
      FROM InputIdAnalysis
     GROUP by inputId, class };

  if( defined $start && defined $count ) {
    $query .= " LIMIT $start,$count";
  }

  my $sth = $self->prepare( $query );
  $sth->execute;

  my %seenhash;

  while( @row = $sth->fetchrow_array ) {
      my $id    = $row[0];
      my $class = $row[1];

      if (!defined($seenhash{$id . "-" . $class})) {
	  push( @result, [ $id, $class ] );
      }
      $seenhash{$id . "-" . $class} = 1;
  }

  return @result;
}

sub delete_inputId_class {
  my $self = shift;
  my ($dbID, $class) = shift;

  my $sth = $self->prepare( qq{
    DELETE FROM InputIdAnalysis
    WHERE  inputId = ?} );
  $sth->execute($dbID);
}

sub db {
  my ( $self, $arg )  = @_;
  ( defined $arg ) &&
    ($self->{_db} = $arg);
  $self->{_db};
}

sub prepare {
  my ( $self, $query ) = @_;
  $self->db->prepare( $query );
}

sub deleteObj {
  my $self = shift;
  my @dummy = values %{$self};
  foreach my $key ( keys %$self ) {
    delete $self->{$key};
  }
  foreach my $obj ( @dummy ) {
    eval {
      $obj->deleteObj;
    }
  }
}

1;
