package Bio::EnsEMBL::Pipeline::GeneDuplication::Result;

use strict;
use vars qw(@ISA);
use Bio::EnsEMBL::Root;


@ISA = qw(Bio::EnsEMBL::Root);




sub new {
  my ($class, @args) = @_;

  my $self = bless {}, $class;

  my ($id,
      $distance_method) = $self->_rearrange([qw(ID
						DISTANCE_METHOD)],@args);

  $id              && $self->query_id($id);
  $distance_method && $self->distance_method($distance_method);

  return $self;
}

sub query_id {
  my $self = shift;

  if (@_) {
    $self->{_query_id} = shift;
  }

  return $self->{_query_id}
}

sub distance_method {
  my $self = shift;

  if (@_) {
    $self->{_distance_method} = shift;
  }

  return $self->{_distance_method}
}

sub add_match {
  my ($self,
      $match_id,
      $nonsyn,
      $syn) = @_;

  die "Dont have a match identifier to store with match." 
    unless $match_id;

  die "Dont have nonsynonymous and synonymous values to store with match."
    unless defined $nonsyn & defined $syn;

  my %match_hash;

  $match_hash{id} = $match_id;
  $match_hash{dN} = $nonsyn;
  $match_hash{dS} = $syn;

  push @{$self->{_matches}}, \%match_hash;

  return 1;
}

sub matches {
  my $self = shift;

  return $self->{_matches}
}



return 1;
