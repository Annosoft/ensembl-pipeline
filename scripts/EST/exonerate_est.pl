#!/usr/local/bin/perl -w

BEGIN {
  # oooh this is not nice
  my $script_dir = $0;
  $script_dir =~ s/(\S+\/)\S+/$1/;
  use lib $script_dir;
  require "EST_conf.pl";
}

=head1 NAME

  exonerate_est.pl

=head1 SYNOPSIS
 
  exonerate_est.pl
  Runs RunnableDB::ExonerateEST over an input estfile and a given genomic file/input id
  Writes output to /tmp
  Moves the /tmp output and errorfiles to specified output directory

=head1 DESCRIPTION


=head1 OPTIONS
   -chunkname name of the EST chunk to run with
   everything else is got from EST_conf.pl configuration file
=cut

use strict;
use Getopt::Long;

my $runner;
my $runnable;
my $dbname;
my $dbuser;
my $host;
my $estfiledir;
my $chunkname;
my $input_id;
my $outdir;
my $errfile;
my $tmperrfile;
my $outfile;
my $tmpoutfile;

&get_variables();

my $estfile = $estfiledir . $chunkname;

my $command = "$runner -runnable $runnable -dbname $dbname -dbuser $dbuser -host $host -input_id $input_id -parameters estfile=$estfile 2>$tmperrfile | gzip -9 >$tmpoutfile";

#print STDERR "command is $command\n";

my $output = `$command`;
#my $output = "";


# $output should be empty if redirect has worked
if ($output eq ''){
  my $mv1 = `mv $tmperrfile $errfile`;
  if($mv1 ne ""){
    warn "\nmessage from moving errfile: $mv1\n";
  }

  my $mv2 = `mv $tmpoutfile $outfile`;
  if($mv2 ne ""){
    print STDERR "message from moving outfile: $mv2\n";
  }
}
else {
  warn "\nproblem with exonerate redirect: $output\n";
}


=head2 get_variables

  Title   : get_variables
  Usage   : get_variables
  Function: initialiases global variables according to input parameters and contents of EST_conf.pl 
            If required parameters are not provided, prints usgae statement and exits script.
  Returns : none - uses globals
  Args    : none - uses globals

=cut

sub get_variables {
  my %conf =  %::EST_conf; # from EST_conf.pl

  &GetOptions( 
	      'chunkname:s'      => \$chunkname,
	     );

  $runner     = $conf{'runner'};
  $runnable   = $conf{'exonerate_runnable'};
  $dbname     = $conf{'refdbname'};
  $dbuser     = $conf{'refdbuser'};
  $host       = $conf{'refdbhost'};
  $estfiledir = $conf{'estfiledir'};
  $input_id   = $conf{'genomic'};
  $outdir     = $conf{'tmpdir'};

  if(!(defined $host       && defined $dbname    && defined $dbuser &&
       defined $runner     && defined $runnable  &&
       defined $estfiledir && defined $chunkname && 
       defined $input_id   && defined $outdir)){
    print "Usage: exonerate_est.pl -chunkname\n" .
      "Additional options to be set in EST_conf.pl: runner, exonerate_runnable, refdbname, refdbuser, refdbhost, estfiledir, genomic and tmpdir\n";
    exit (1);
  }

  # output directories have been created by make_bsubs.pl
  $outdir .= "/exonerate_est/result/";
  my $errdir = $outdir . "stderr/";
  $outdir .= "stdout/";

  die("can't open directory $errdir\n") unless opendir(DIR, $errdir);
  closedir DIR;
  
  die("can't open directory $outdir\n") unless opendir(DIR, $outdir);
  closedir DIR;

  my $err     =  "exest_"      . $chunkname . "_" . $$ . ".stderr";
  $errfile    = $errdir . $err;
  $tmperrfile = "/tmp/" . $err;

  my $out     = "exest_"      . $chunkname . "_" . $$ . ".stdout.gz";
  $outfile    = $outdir . $out;
  $tmpoutfile = "/tmp/" . $out;

}
