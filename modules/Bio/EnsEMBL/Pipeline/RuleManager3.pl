# Script for operating the analysis pipeline
#
# You may distribute this code under the same terms as perl itself


use strict;
use Getopt::Long;
use Sys::Hostname;
use Socket;

use Bio::EnsEMBL::Pipeline::DBSQL::DBAdaptor;


use Bio::EnsEMBL::Pipeline::Config::General;
use Bio::EnsEMBL::Pipeline::Config::BatchQueue;


unless (&config_sanity_check) {
    exit 1;
}


# Also, an alarm is set to go off every (say) 2 minutes (or not at all if
# $wakeup is false). When the script receives this it looks to see how many
# jobs are in the queue and, if there too many, goes to sleep for a while.
# You could also do this by counting the number of distinct(LSF_id) entries
# in the job table but you would have to also check for dead processes etc.
# It looks for failed jobs as well and restarts them.

# signal parameters
my $term_sig =  0;
my $rst_sig  =  0;
my $alarm    =  0;
my $wakeup   =  120;   # period to check batch queues; set to 0 to disable

# the signal handlers
$SIG{USR1} = \&sighandler;
$SIG{ALRM} = \&alarmhandler;
$SIG{TERM} = \&termhandler;
$SIG{INT} = \&termhandler;


# dynamically load appropriate queue manager (e.g. LSF)





# command line options override 
# anything set in the environment variables.

my $dbhost    = $ENV{'ENS_DBHOST'};
my $dbname    = $ENV{'ENS_DBNAME'};
my $dbuser    = $ENV{'ENS_DBUSER'};
my $dbpass    = $ENV{'ENS_DBPASS'};
my $dbport    = $ENV{'ENS_DBPORT'} || 3306;

$| = 1;

my $local        = 0;       # Run failed jobs locally
my @analyses;               # Only run this analysis ids
my $submitted;
my $idlist_file;
my ($done, $once);
my $runner;
my $shuffle;  
my $output_dir;
my %analyses;
my $verbose;
my $rerun_sleep = 3600;
my $overload_sleep = 300;
my $max_time;
my $killed_file;
my @input_id_types;
my @starts_from;
my $queue_manager;
my $accumulators = 1; #these two options are on as default but that can 
my $db_sanity = 1; #be switched off by sticiking no infront of the 
                   #standard command line options (see GetOpts long docs)
my $help;
my $rename_on_retry = 1;

GetOptions(
    'dbhost=s'      => \$dbhost,
    'dbname=s'      => \$dbname,
    'dbuser=s'      => \$dbuser,
    'dbpass=s'      => \$dbpass,
    'dbport=s'      => \$dbport,
    'local'         => \$local,
    'idlist_file=s' => \$idlist_file,
    'runner=s'      => \$runner,
    'output_dir=s'  => \$output_dir,
    'once!'         => \$once,
    'shuffle!'      => \$shuffle,
    'analysis=s@'   => \@analyses,
    'input_id_types=s@' => \@input_id_types,
    'start_from=s@' => \@starts_from,	   
    'v|verbose!'            => \$verbose,
    'dbsanity!'     => \$db_sanity,
    'accumulators!' => \$accumulators,
    'max_job_time=s' => \$max_time,
    'killed_file=s' => \$killed_file,
    'queue_manager=s' => \$queue_manager,	   
    'h|help'	    => \$help,
    'rename_on_retry!' => \$rename_on_retry,	   
) or useage();

if(!$dbhost || !$dbname || !$dbuser){
  print STDERR " you must provide a host and a database name and a user".
  " for you db connection\n";
  $help = 1;
}

useage() if $help;

if($idlist_file || @analyses || @input_id_types || @starts_from){
  print STDERR " you are running the rulemanager in a fashion which"
  ." will probably break the accumulators so they are being "
  ."turned off\n";

  $accumulators = 0;
} 
my $max_time = $MAX_JOB_TIME unless($max_time);
my $killed_file = $KILLED_INPUT_IDS unless($killed_file);
my $queue_manager = $QUEUE_MANAGER unless($queue_manager);

my $batch_q_module = 
  "Bio::EnsEMBL::Pipeline::BatchSubmission::$queue_manager";

my $file = "$batch_q_module.pm";
$file =~ s{::}{/}g;
eval {
    require "$file";
};
if ($@) {
    print STDERR "Error trying to load $batch_q_module;\ncan't find $file\n";
    exit 1;
}

my $get_pend_jobs;
if ($batch_q_module->can("get_pending_jobs")) {
    my $f = $batch_q_module . "::get_pending_jobs";
    $get_pend_jobs = \&$f;
}

unless ($dbhost && $dbname && $dbuser) {
    print STDERR "Must specify database with -dbhost, -dbname, -dbuser and -dbpass\n";
    exit 1;
}


my $db = Bio::EnsEMBL::Pipeline::DBSQL::DBAdaptor->new(
    -host   => $dbhost,
    -dbname => $dbname,
    -user   => $dbuser,
    -pass   => $dbpass,
    -port   => $dbport,
);


if($db_sanity){
  &db_sanity_check($db);
}else{
  print STDERR "You are not checking db sanity are you sure you set it ".
    "up correctly?\n" if($verbose);
}

my $rule_adaptor = $db->get_RuleAdaptor;
my $job_adaptor  = $db->get_JobAdaptor;
my $ana_adaptor  = $db->get_AnalysisAdaptor;
my $sic          = $db->get_StateInfoContainer;

# analysis options are either logic names or analysis dbID's



%analyses   = logic_name2dbID($ana_adaptor, @analyses);
my %tmp = logic_name2dbID($ana_adaptor, @starts_from);
@starts_from = keys %tmp;

if ($idlist_file && ! -e $idlist_file) {
    die "Must be able to read $idlist_file";
}


# Lock to prevent >1 instances of the same pipeline running together
#
# Puts an entry in the meta table keyed on 'pipeline.lock', which
# gives the host running the script, user, PID and when it was
# started

if (my $lock_str = $db->pipeline_lock) {
    # Another pipeline is running: describe it
    my($user, $host, $pid, $started) = $lock_str =~ /(\w+)@(\w+):(\d+):(\d+)/;
    $started = scalar localtime $started;

    print STDERR <<EOF;
Error: this pipeline appears to be running!

    db       $dbname\@$dbhost
    pid      $pid on host $host
    started  $started

The process above must be terminated before this script can be run.
If the process does not exist, remove the lock by removing the lock
from the pipeline database:

    delete from meta where meta_key = 'pipeline.lock';

Thank you


EOF

    exit 1;
}

# create lock

my $host = &qualify_hostname(hostname());
my $user = scalar getpwuid($<);
my $lock_str = join ":", "$user\@$host", $$, time();
$db->pipeline_lock($lock_str);


# Fetch all the analysis rules.  These contain details of all the
# analyses we want to run and the dependences between them. e.g. the
# fact that we only want to run blast jobs after we've repeat masked etc.

my @rules       = $rule_adaptor->fetch_all;

my %accumulator_analyses;

foreach my $rule (@rules) {
  if ($rule->goalAnalysis->input_id_type eq 'ACCUMULATOR') {
    $accumulator_analyses{$rule->goalAnalysis->logic_name} = $rule->goalAnalysis;
  }
}

# Need here to strip rules which don't need to be run.

my @id_list;     # All the input ids to check

alarm $wakeup if $wakeup;  
                # Signal to the script to do something in the future,
                # Such as check for failed jobs, no of jobs in queue

my %completed_accumulator_analyses;
my %ids_to_run;
my %types_to_run;

if($idlist_file){
  open IDS, "< $idlist_file" or die "Can't open $idlist_file";
  my $count = 0;
  while (<IDS>) {
    chomp;
    my($id, $type) = split;
    if(!$type){
      print STDERR "need to know what type the input ids in the file".
	" are  format should be input_id type\n";
    }
    $ids_to_run{$type}{$id} = 1;
  }
  close IDS;
}

if(@input_id_types){
  foreach my $type(@input_id_types){
    $types_to_run{$type} = 1;
  }
}

while (1) {
    $submitted = 0;

    # This loop reads input ids from the database a chunk at a time
    # until we have all the input ids.

    my $id_type_hash = {};
    print "Reading IDs ... ";
    if ($idlist_file) {
      $id_type_hash = \%ids_to_run;
    }else {

      if(@starts_from){
	foreach my $analysis_id(@starts_from){
	  my %ids;
	  my $analysis = $ana_adaptor->fetch_by_dbID($analysis_id);
	  my @ids = @{$sic->list_input_ids_by_analysis($analysis_id)};
	  foreach my $id(@ids){
	    $ids{$analysis->input_id_type}{$id} = 1;
	  }
	  $id_type_hash = \%ids;
	}
      }else{
	$id_type_hash = $sic->get_all_input_id_analysis_sets;
      }
    }

    my @anals = @{$sic->fetch_analysis_by_input_id('ACCUMULATOR')};

    foreach my $anal (@anals) {
        if ($anal->input_id_type eq 'ACCUMULATOR') {
            print "Adding completed accumulator for " . $anal->logic_name . "\n";

            $completed_accumulator_analyses{$anal->logic_name} = 1;
        } else {
            print STDERR "WARNING: Expected input_id_type to be ACCUMULATOR for input_id ACCUMULATOR\n"
        }
    }

    # Now we loop over all the input ids. We fetch all the analyses
    # from the database that have already run. We then check all the
    # rules to see which new analyses can be run.  e.g. if we've run
    # RepeatMasker we can run genscan. If we've run genscan we can run
    # blast jobs.
    #
    # All the analyses we're allowed to run are stored in a hash %analHash

    my %incomplete_accumulator_analyses;

    INPUT_ID_TYPE: foreach my $input_id_type (keys %$id_type_hash) {
	
        next INPUT_ID_TYPE if ($input_id_type eq 'ACCUMULATOR');
	if(keys(%types_to_run) && !$types_to_run{$input_id_type}){
	  next;
	}
	if($batch_q_module->can('get_job_time')){
	  if($killed_file){
	    my @running_jobs = $job_adaptor->fetch_by_Status('RUNNING');
	    &job_time_check($batch_q_module, $verbose, \@running_jobs, 
			    $killed_file, $max_time);
	  }
	}

        @id_list = keys %{$id_type_hash->{$input_id_type}};

        @id_list = &shuffle(@id_list) if $shuffle;

        print "Checking $input_id_type ids\n";

        JOBID: foreach my $id (@id_list) {
    
            # handle signals. they are 'caught' in the handler subroutines but
            # it is only here they we do anything with them. so if the script
            # is doing something somewhere else (getting IDs at the start of
            # the while loop) or dozing, we have to wait until it gets here to
            # do anything...
    
            if ($alarm == 1) {
                $alarm = 0;
    
                # retry_failed_jobs($job_adaptor, $DEFAULT_RETRIES);
                while ($get_pend_jobs && !$term_sig && &$get_pend_jobs >= $MAX_PENDING_JOBS) {
                    sleep $overload_sleep;
                }
                alarm $wakeup;
            }
    
            if ($term_sig) {
                $done = 1;
                last INPUT_ID_TYPE;
            }
    
            if ($rst_sig) {
                $done = 0;
                @rules = $rule_adaptor->fetch_all;
                last INPUT_ID_TYPE;
            }
    
            my @anals = @{$sic->fetch_analysis_by_input_id($id)};
    
            my %analHash;
    
            # check all rules, which jobs can be started
    
            my @current_jobs = $job_adaptor->fetch_by_input_id($id);
    
            RULE: for my $rule (@rules)  {
                if (keys %analyses && ! defined $analyses{$rule->goalAnalysis->dbID}) {
                    if ($rule->goalAnalysis->input_id_type eq 'ACCUMULATOR') {
                        $incomplete_accumulator_analyses{$rule->goalAnalysis->logic_name} = 1;
                    }
                    next RULE;
                }
                print "Check ",$rule->goalAnalysis->logic_name, " - " . $id if $verbose;
	
		
                my $anal = $rule->check_for_analysis (\@anals, $input_id_type, \%completed_accumulator_analyses, $verbose);
		
		if(UNIVERSAL::isa($anal,'Bio::EnsEMBL::Pipeline::Analysis')){
                    print " fullfilled.\n" if $verbose;
                    if ($rule->goalAnalysis->input_id_type ne 'ACCUMULATOR') {
                      $analHash{$anal->dbID} = $anal;
                    }
                } else {
                    print " not fullfilled.\n" if $verbose;

                    if ($rule->goalAnalysis->input_id_type eq 'ACCUMULATOR' &&
                        $rule->has_condition_of_input_id_type($input_id_type) ) {

	
                        print " Makes ACCUMULATOR " . $rule->goalAnalysis->logic_name  . " incomplete\n" if($verbose);
                        $incomplete_accumulator_analyses{$rule->goalAnalysis->logic_name} = 1;
                    }
                }
            }
    
            # Now we loop over all the allowed analyses in the hash. We
            # first check the database to see if the job is already running.
            # If so we skip it.
            #
            # If all is ok we create a new job, store it in the database and
            # submit it to the batch runner. This will keep a check of the
            # number of jobs created. When $flushsize jobs have been stored
            # send to LSF.
    
            ANAL: for my $anal (values %analHash) {
                my $result_flag = run_if_new($id,
                                             $anal,
                                             \@current_jobs,
                                             $local,
                                             $verbose,
                                             $output_dir,
                                             $job_adaptor);

                if ($result_flag == -1) {
                    next JOBID;
                } elsif ($result_flag == 0) {
                    next ANAL;
                } else { 
                    $submitted++;
                }
            }
        }
    }

    if ( ! $done) {
      if($accumulators){# this option means you can turn off accumulators
	#checks if you don't want them checked or they don't need to be
	#checked, it is on as standard
	#$verbose = 1;
        my @current_jobs = $job_adaptor->fetch_by_input_id('ACCUMULATOR');
        foreach my $accumulator_logic_name (keys %accumulator_analyses) {
            print "Checking accumulator type analysis $accumulator_logic_name\n" if $verbose;
            if (!exists($incomplete_accumulator_analyses{$accumulator_logic_name}) &&
                !exists($completed_accumulator_analyses{$accumulator_logic_name})) {
                my $result_flag = run_if_new('ACCUMULATOR',
                                             $accumulator_analyses{$accumulator_logic_name},
                                             \@current_jobs,
                                             $local,
                                             $verbose,
                                             $output_dir,
                                             $job_adaptor);
                if ($result_flag == 1 && $verbose) { 
		  print "Started accumulator type job for anal ".
		    "$accumulator_logic_name\n"; 
		   $submitted++; 
		}
    
            } elsif (exists($incomplete_accumulator_analyses{$accumulator_logic_name})) {
                print "Accumulator type analysis $accumulator_logic_name conditions unsatisfied\n" if $verbose;
            } else {
                print "Accumulator type analysis $accumulator_logic_name already run\n" if $verbose;
            }
        }
      }
    }
    #$verbose = 0;
    if($done || $once){
      &shut_down($db);
    }else{
      &cleanup_waiting_jobs($db);
    }
    sleep($rerun_sleep) if $submitted == 0;
    @id_list = ();
    print "Waking up and run again!\n" if $verbose;
}


sub run_if_new {
    my ($id, $anal, $current_jobs, $local, $verbose, $output_dir, $job_adaptor) = @_;

    print "Checking analysis " . $anal->dbID . "\n\n" if $verbose;
    # Check whether it is already running in the current_status table?

    my $retFlag=0;
    eval {
        foreach my $cj (@$current_jobs) {

             print "Comparing to current_job " . $cj->input_id . " " .
                  $cj->analysis->dbID . " " .
                  $cj->current_status->status . " " .
                  $anal->dbID . "\n" if $verbose;

            if ($cj->analysis->dbID == $anal->dbID) {
                if ($cj->current_status->status eq 'FAILED' && $cj->retry_count <= $DEFAULT_RETRIES) {
		  if($rename_on_retry){
		    if( -e $cj->stdout_file ) { 
		      my $cmd = "mv ".$cj->stdout_file." ".$cj->stdout_file.
			".retry.".$cj->retry_count;
		      system($cmd);
 
		    }
		    if( -e $cj->stderr_file ) {
		      my $cmd = "mv ".$cj->stderr_file." ".$cj->stderr_file.
			".retry.".$cj->retry_count;
		      system($cmd);
		    }
		  }
                    $cj->batch_runRemote;
                    print "Retrying job\n" if $verbose;
                }
                else {
                    print "\nJob already in pipeline with status : " . $cj->current_status->status . "\n" if $verbose ;
                }
                $retFlag = 1;
            }
        }
    };


    if ($@) {
        print "ERROR: comparing to current jobs. Skipping analysis for " . $id . " [$@]\n";
        return -1;
    } elsif ($retFlag) {
        return 0;
    }
    #print STDERR "creating job with ".$PIPELINE_RUNNER_SCRIPT."\n";
    my $job = Bio::EnsEMBL::Pipeline::Job->new(-input_id => $id,
                                               -analysis => $anal,
                                               -output_dir => $output_dir,
                                               -runner => $PIPELINE_RUNNER_SCRIPT);


    print "Store ", $id, " - ", $anal->logic_name, "\n" if $verbose;
    $job_adaptor->store($job);

    if ($local) {
        print "Running job locally\n" if $verbose;
        eval {
          $job->runLocally;
        };
        if ($@) {
           print STDERR "ERROR running job " . $job->dbID .  " "  . $job->stderr_file . "[$@]\n";
        }
    } else {
        eval {
            print "\tBatch running job\n" if $verbose;
            $job->batch_runRemote;
        };
        if ($@) {
            print STDERR "ERROR running job " . $job->dbID . " " . $job->stderr_file . " [$@]\n";
        }
    }
    return 1;
}

# remove 'lock'
sub shut_down {
    my ($db) = @_;

    my ($a_job) = $db->get_JobAdaptor->fetch_by_Status("CREATED");
    if ($a_job) {
        $a_job->flush_runs($db->get_JobAdaptor);
    }
    $db->pipeline_unlock;
    exit 0;
}


#this method should ensure any jobs hanging around after a complete
#cycle of the central loop are run regardless whether batch size is met
#or not
sub cleanup_waiting_jobs{
  my ($db) = @_;

    my ($a_job) = $db->get_JobAdaptor->fetch_by_Status("CREATED");
    if ($a_job) {
        $a_job->flush_runs($db->get_JobAdaptor);
    } 
}

# handler for SIGTERM
sub termhandler {
    $term_sig = 1;
}


# handler for SIGUSR1
sub sighandler {

    $rst_sig = 1;
    $SIG{SIG1} = \&sighandler;
};


# handler for SIGALRM
sub alarmhandler {
    $alarm = 1;
    $SIG{ALRM} = \&alarmhandler;
}


# turn a name of the form 'ecs1a' into 'ecs1a.sanger.ac.uk'
sub qualify_hostname {
    my ($hostname) = @_;

    my $addr = gethostbyname($hostname);

    my $host = gethostbyaddr($addr, AF_INET);

    return $host;
}


sub retry_failed_jobs {
    my ($ja, $retry) = @_;

    my @failed_jobs = @{$ja->list_job_id_by_status('FAILED')};

    foreach my $jobId (@failed_jobs) {
        my $job = $ja->fetch_by_dbID($jobId);
        if ($job->retry_count <= $retry) {
            $job->batch_runRemote;

        }
    }
}


# NB Incomplete
# Delete RUNNING jobs which are not known to LSF.
sub check_lsf_status {
    my ($LSF_params) = @_;

    my $queue = $LSF_params->{'queue'};
    my (%lsf_id, %jobs);
    my $ja = $db->get_JobAdaptor;

    my $age = 300;   # 5 hours

    my $lsf = Bio::EnsEMBL::Pipeline::LSF->new(
        -queue => $queue,
        # -user  => $username,
    );

    foreach my $job ($lsf->get_all_jobs()) {
        my $stat = $job->status;
        my $id   = $job->id;
        $jobs{$stat}++;
        $lsf_id{$id} = 1;
    }

    foreach my $job ($db->fetch_by_Age($age)) {
        my $lsf = $job->submission_id;
        local $_ = $job->get_last_status->status;   # Are you local?
        STAT: {
            /RUNNING/ && do {
                #$job->remove unless defined $lsf_id{$lsf};
                last STAT;
            };
            /SUBMITTED/ && do {
                last STAT;
            };
        } # STAT
    }
}


sub shuffle {
    my (@in) = @_;
    my @out;

    srand;

    push @out, splice(@in, rand @in, 1) while @in;

    return @out;
}


sub config_sanity_check {
    my $ok = 1;
    no strict 'vars';
    print STDERR "checking config sanity\n";
    unless ($QUEUE_MANAGER) {
        print "Need to specify QUEUE_MANAGER in Config/BatchQueue.pm\n";
	$ok = 0;
    }
    unless ($LIB_DIR) {
        print "Need to specify LIB_DIR in Config/General.pm\n";
	$ok = 0;
    }
    unless ($DATA_DIR) {
        print "Need to specify DATA_DIR in Config/General.pm\n";
	$ok = 0;
    }
    unless ($BIN_DIR) {
        print "Need to specify BIN_DIR in Config/General.pm\n";
	$ok = 0;
    }

    return $ok;
}


sub logic_name2dbID {
    my ($ana_adaptor, @analyses) = @_;
    my %analyses;

    foreach my $ana (@analyses) {
        if ($ana =~ /^\d+$/) {
            $analyses{$ana} = 1;
        }
        else {
	    my $id = $ana_adaptor->fetch_by_logic_name($ana)->dbID;
	    if ($id) {
                $analyses{$id} = 1;
	    }
	    else {
	        print STDERR "Could not find analysis $ana\n";
	    }
        }
    }
    return %analyses;
}

sub db_sanity_check{
  my ($db) = @_;

  my ($query, $msg);
  #check all rules in the rule_goal table have existing analyses
  $query = qq{SELECT COUNT(DISTINCT g.rule_id)
                FROM rule_goal g
                LEFT JOIN analysis a ON g.goal = a.analysis_id
	        WHERE a.analysis_id IS NULL};
  $msg = "Some of your goals in the rule_goal table don't seem".
         " to have entries in the analysis table";
  execute_sanity_check($db, $query, $msg);
  #check all rules in the rule_condition table have existing analyses
  $query = qq{SELECT COUNT(DISTINCT c.rule_id)
                FROM rule_conditions c
                LEFT JOIN analysis a ON c.condition = a.logic_name
	        WHERE a.logic_name IS NULL};
  $msg = "Some of your conditions in the rule_condition table don't" .
         " seem to have entries in the analysis table";
  execute_sanity_check($db, $query, $msg);
  #check all the analyses have types
  $query = qq{SELECT COUNT(DISTINCT(a.analysis_id))
                FROM analysis a
                LEFT JOIN input_id_type_analysis t ON a.analysis_id = t.analysis_id
	        WHERE t.analysis_id IS NULL};
  $msg = "Some of your analyses don't have entries in the".
         " input_id_type_analysis table"; 
  execute_sanity_check($db, $query, $msg);
  #check that all types which aren't accumulators have entries in
  #input__id_analysis table
  $query = qq{SELECT DISTINCT(t.input_id_type)
                FROM input_id_analysis i 
                LEFT JOIN input_id_type_analysis t ON i.input_id_type = t.input_id_type
	        WHERE t.input_id_type IS NULL
                && t.input_id_type != 'ACCUMULATOR'};
  $msg = "Some of your types don't have entries in the".
         " input_id_type_analysis table";
  execute_sanity_check($db, $query, $msg);
}
sub execute_sanity_check{
    my ($db, $query, $msg) = @_;
    my $sth = $db->prepare($query);
    $sth->execute();
    die $msg if $sth->fetchrow();
}

sub job_time_check{
  my ($batch_q_module, $verbose, $running_jobs, $file, $time) = @_;
   open(KILLED, "+>>".$file) or die("couldn't open ".$file." $!");
  foreach my $job(@$running_jobs){
    my $time = $batch_q_module->get_job_time($job->submission_id);
    if($time >= $max_time){
      $batch_q_module->kill_job($job->submission_id);
      print KILLED $job->input_id." ".$job->analysis->logic_name." ".$job->analysis->module."\n";
      print STDERR $job->input_id." ".$job->analysis->logic_name." ".$job->analysis->module."\n" if($verbose);
      $job->set_status('KILLED');
    }
  }

}

sub useage{
	exec('perldoc', $0);
	exit;
}

=pod

=head1 NAME

monitor

=head1 SYNOPSIS

RuleManager3.pl, a script to run the pipeline

=head1 OPTIONS

DB Connection Details


   -dbhost     The host where the pipeline database is.
   -dbport     The port.
   -dbuser     The user to connect as.
   -dbpass     The password to use.
   -dbname   The database name.

Other Options

   -local run the pipeline locally and not using the batch submission 
    system
   -idlist_file a path to a file containing a list of input ids to use
    this file need to be in the format input_id input_type, for example
    1.1-100000 SLICE
   -runner path to a runner script (if you want to overide the setting
				    in BatchQueue.pm)
   -output_dir path to a output dir (if you want to overide the 
				     setting in BatchQueue.pm)
   -once only run through the RuleManager loop once
   -shuffle before running though the loop shuffle the order of the 
    input ids
   -analysis only run with these analyses objects, can be logic_names or
    analysis ids, this option can appear in the commandline multiple 
    times
   -v verbose mode
   -dbsanity peform some db sanity checks, can be switched of with 
    -nodbsanity
   -input_id_types, which input id types to run the RuleManager with,
    this option can also appear in the commandline multiple times
   -start_from, this is which analysis to use to gather the input ids
    which will be checked by the RuleManagers central loop
   -accumulators, this flag switches the accumulators on, the 
    accumulators are on by default but can be swtiched on with the 
    -noaccumulators flag
   -max_job_time, can overide the $MAX_JOB_TIME value from General.pm
    with this flag
   -killed_file can overide the path to the $KILLED_INPUT_IDS file from
    General.pm
   -queue_manager can overide the $QUEUE_MANAGER from General.pm
   -rename_on_retry, this means any output already produced will be deleted
    before a job is retried, this defaults to off currently, it was put in 
    as LSF appends output and error files and sometimes you don't want this'
   
-h or -help will print out the help again

NOTE: using the -start_from, -input_id_types, -analysis or -idlist_file
options automatically switched off the accumulators

=head1 EXAMPLES

a standard run of the pipeline would look like this


perl RuleManager3.pl -dbhost ecs2b -dbuser ensadmin -dbpass ****
 -dbname pipeline_db -shuffle

if you wished to specify specific analysis to 

perl RuleManager3.pl -dbhost ecs2b -dbuser ensadmin -dbpass ****
 -dbname pipeline_db -analysis RepeatMask -analysis Swall

this would only run the RepeatMask and Swall analyses

perl RuleManager3.pl -dbhost ecs2b -dbuser ensadmin -dbpass ****
 -dbname pipeline_db -analysis RepeatMask -local

this would only run the RepeatMask analysis locally

obviously when specific analyses are specified their conditions must be 
met otherwise they still won't be run'

=head1 SEE ALSO

  Bio::EnsEMBL::Pipeline::Job
  Bio::EnsEMBL::Pipeline::Config::General
  Bio::EnsEMBL::Pipeline::Config::BatchQueue

and also using_the_ensembl_pipeline.txt in the ensembl-docs cvs module

=cut
