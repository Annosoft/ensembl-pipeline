## Bioperl Test Harness Script for Modules
##


# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.t'

#-----------------------------------------------------------------------
## perl test harness expects the following output syntax only!
## 1..3
## ok 1  [not ok 1 (if test fails)]
## 2..3
## ok 2  [not ok 2 (if test fails)]
## 3..3
## ok 3  [not ok 3 (if test fails)]
##
## etc. etc. etc. (continue on for each tested function in the .t file)
#-----------------------------------------------------------------------


## We start with some black magic to print on failure.
BEGIN { $| = 1; print "1..2\n"; 
	use vars qw($loaded); }

END {print "not ok 1\n" unless $loaded;}

use Bio::EnsEMBL::Pipeline::ExonPair;
use Bio::EnsEMBL::Exon;

$loaded = 1;
print "ok 1\n";    # 1st test passes.


$exon1 = Bio::EnsEMBL::Exon->new();
$exon1->start(10);
$exon1->end(20);
$exon1->strand(1);
$exon1->contig_id('AC00013.1');

$exon2 = Bio::EnsEMBL::Exon->new();
$exon2->start(30);
$exon2->end(40);
$exon2->strand(1);
$exon2->contig_id('AC00013.1');

$ep = Bio::EnsEMBL::Pipeline::ExonPair->new( -exon1 => $exon1,
					     -exon2 => $exon2,
                                             -type  => 'silly');

if( !defined $ep ) {
	print "not ok 2\n";
} else {
	print "ok 2\n";
}
