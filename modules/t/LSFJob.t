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
BEGIN { $| = 1; print "1..3\n"; 
	use vars qw($loaded); }

END {print "not ok 1\n" unless $loaded;}


use Bio::EnsEMBL::Pipeline::LSFJob;

$loaded = 1;
print "ok 1\n";    # 1st test passes.

$job = Bio::EnsEMBL::Pipeline::LSFJob->new(
					   -id => 12323,
					   -user => 'humpub',
					   -status => 'running',
					   -queue => 'blast_farm',
					   -from_host => 'monkey',
					   -exec_host => 'blast12',
					   -job_name => 'something',
					   -submission_time => 955654221
					   );

print "ok 2\n";

$job->id;
$job->user;
$job->status;
$job->queue;
$job->from_host;
$job->exec_host;
$job->job_name;
$job->submission_time;

print "ok 3\n";
					   
