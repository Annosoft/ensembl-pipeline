#
# PipelineManager.pm - A module for running and controlling a pipeline
#
# 
# You may distribute this module under the same terms as perl itself
#

=pod 

=head1 NAME

Bio::EnsEMBL::Pipeline::PipelineManager - Singleton class responsible for 
controlling and running a pipeline system

=head1 SYNOPSIS

  use Bio::EnsEMBL::Pipeline::PipelineManager;
  use Bio::EnsEMBL::Pipeline::Pipeline::Config;

  my $config = Bio::EnsEMBL::Pipeline::Config->new(-files => \@_);
  my $pm = Bio::EnsEMBL::Pipeline::PipelineManager->new($config);

  $pm->run();

=head1 DESCRIPTION

This module manages a pipeline.  It is responsible for ensuring that the 
correct task modules run at the correct times and for maintaining 
submission systems.  The configuration module passed into the Pipeline 
constructor specifies which tasks form the pipeline system, and which 
submission systems will be used.

The pipeline manager may be stopped and restarted without problem.  Jobs
which are already running will continue to run in the background/farm if the
manager is stopped. When the manager is restarted jobs which were not submitted
will be recreated and the system will essentially pick up where it left off.

The recommended way of starting the pipeline manager is through the use
of the the startPipeline.pl script:

  #start the pipeline
  perl startPipeline.pl -file conf.file
  
  #restart the pipeline using a config already loaded in the db
  perl startPipeline.pl -dbname hs_pipe -host ecs1g -user ensadmin -pass passw


=head1 CONTACT

ensembl-dev@ebi.ac.uk

=head1 APPENDIX

The rest of the documentation details each of the object
methods. Internal methods are usually preceded with a _

=cut

use strict;
use warnings;

package Bio::EnsEMBL::Pipeline::PipelineManager;

use Bio::EnsEMBL::Root;

use vars qw(@ISA);

@ISA = qw(Bio::EnsEMBL::Root);


=head2 new

  Arg [1]    : Bio::EnsEMBL::Pipeline::Config
  Example    : $pipelineManager = Bio::EnsEMBL::PipelineManager->new($config);
  Description: Creates a new PipelineManager object.  This constructor
               is responsible for initialising the tasks to be run
               and the various submission systems.
  Returntype : Bio::EnsEMBL::Pipeline::PipelineManager
  Exceptions : thrown if incorrect arguments supplied
  Caller     : pipelineManager.pl script

=cut

sub new {
  my $caller = shift;
  my $config = shift;

  my $class = ref($caller) || $caller;

  my $self = bless {'config' => $config}, $class;

  ref($config) && $config->isa('Bio::EnsEMBL::Pipeline::Config') ||
    $self->throw('Bio::EnsEMBL::PipelineConfig argument is required');

  $self->_create_tasks();
  $self->_create_submission_systems();

  return $self;
}



=head2 stop

  Arg [1]    : none
  Example    : while(!$pipelineManager->stop()) { do_something(); }
  Description: This will return true if the pipeline should stop.
               A signal handler registered in the script which starts the
               pipeline manager is responisble for setting the flag.
  Returntype : boolean
  Exceptions : none
  Caller     : run() method

=cut

sub stop {
  my $self = shift;

  return $self->{'stop'};
}



=head2 get_Config

  Arg [1]    : none
  Example    : $config = $pipeline_manager->get_Config();
  Description: Getter for the configuration object associated with this
               pipeline manager
  Returntype : Bio::EnsEMBL::Pipeline::Config
  Exceptions : none
  Caller     : general

=cut

sub get_Config {
  my $self = shift;
	
  return $self->{'config'};
}



=head2 get_TaskStatus

  Arg [1]    : string $taskname
  Example    : $task_status = $pipeline_manger->get_TaskStatus($task->name());
  Description: Retrieves the current status of a task via the tasks name
  Returntype : Bio::EnsEMBL::Pipeline::TaskStatus
  Exceptions : none
  Caller     : general

=cut

sub get_TaskStatus {
  my $self = shift;
  my $taskname = shift;

  $taskname = lc($taskname);

  my $task = $self->_tasks()->{$taskname};
  if(!$task) {
    my $tlist = join("\n  ", keys %{$self->_tasks()});

    $self->throw("Don't know anything about task [$taskname]\n" .
                 "Known Tasks:\n  $tlist");
  }
  return $task->get_TaskStatus();
}


=head2 _create_tasks

  Arg [1]    : none
  Example    : none
  Description: Private method.  Called by constructor to create the tasks
               which were read in from the configuration.
  Returntype : none
  Exceptions : none
  Caller     : constructor

=cut

sub _create_tasks {
  my $self = shift;

  #get the config and instantiate all tasks
  my $config = $self->get_Config();
  foreach my $taskname ($config->get_keys('TASKS')) {
    #print STDERR "instantiating task ".$taskname."\n";
    my $module = $config->get_parameter('TASKS', $taskname); 
    eval "require $module";

    if($@) {
      $self->throw("$module cannot be found for task $taskname.\n" .
		   "Exception $@\n");
    }
    my $task = "$module"->new(
			      -TASKNAME => $taskname,
			      -PIPELINE_MANAGER => $self,
			     );

    $self->_tasks()->{$taskname} = $task;
  }
}


=head2 _create_submission_systems

  Arg [1]    : none
  Example    : none
  Description: Private method.  Called by constructor to create the submission
               systems specified in the configuration
  Returntype : none
  Exceptions : none
  Caller     : constructor

=cut

sub _create_submission_systems {
  my $self = shift;

  #get the config and instantiate all tasks
  my $config = $self->get_Config();

  my %submission_systems;
  my %tasks;

  #
  # Get a list of unique submission systems
  #
  foreach my $taskname ($config->get_keys('TASKS')) {
    my $where = $config->get_parameter($taskname, 'where');

    #the submission system is the 'where' value before the first ':'
    my $idx = index($where, ':');
    my $system;
    if($idx == -1) {
      $system = substr($where, 0);
    } else {
      $system = substr($where, 0, $idx);
    }

    $submission_systems{$system} = 1;
    $tasks{$taskname} = $system;
  }

  #
  #instantiate each of the submission systems
  #
  foreach my $ss (keys %submission_systems) {
    my $module = "Bio::EnsEMBL::Pipeline::SubmissionSystem::$ss";
    eval "require $module";
    if($@) {
      $self->throw("$module cannot be found for submission system $ss.\n" .
		   "Exception $@\n");
    }

    my $subsys = $module->new($config);

    $submission_systems{$ss} = $subsys;
  }

  #
  # Associate a submission system and parameters with each task
  #
  foreach my $taskname (keys %tasks) {
    my $system = $submission_systems{$tasks{$taskname}};
    $self->_submission_systems()->{$taskname} = $system;
  }
}


=head2 run

  Arg [1]    : none
  Example    : $pipeline_manager->run();
  Description: Starts the running of the pipeline manager.  This method
               will not return until the pipeline has finished running or
               the runnning is interrupted.
  Returntype : none
  Exceptions : none
  Caller     : general

=cut

sub run {
  my $self = shift;

  #
  # We maintain three lists: pending tasks, running tasks, finished tasks
  #
  my %pending_tasks = %{$self->_tasks() || {}};
  my %running_tasks;
  my %finished_tasks;

  my $config = $self->get_Config();

  my $CHECK_INTERVAL = 
    $config->get_parameter('Pipeline_Manager', 'check_interval') || 120;

  my $last_check = 0;
  my $just_started = 1;

  #
  # MAIN LOOP
  #
 MAIN: while(!$self->stop()) {
    if(!keys(%pending_tasks) && !keys(%running_tasks)) {
      print STDERR "\n\nNothing left to do, shutting down\n";
      last MAIN;
    }

    if(time() - $last_check >= $CHECK_INTERVAL) {	
      #
      # update task status by contacting job adaptor
      #
      $self->_update_task_status($just_started);

      if($just_started) {
        $just_started = 0;
      } else {
        # periodically flush created jobs in case a task forgot to return
        # a TASK_DONE response
        foreach my $taskname (keys %running_tasks) {
          $self->_submission_systems->{$taskname}->flush($taskname);
        }	
      }

      $last_check = time();
    }

    #
    # check if any pending tasks can start running
    #
    foreach my $taskname (keys %pending_tasks) {
      my $task = $pending_tasks{$taskname};
      if($task->can_start()) {
        #print STDERR $taskname." can start\n";
        delete $pending_tasks{$taskname};
        $running_tasks{$taskname} = $task;
      }

      last MAIN if($self->stop);
    }


    #
    # Check if any running tasks are finished 
    #
    my $any_finished = 0;
    foreach my $taskname (keys %running_tasks) {
      my $task = $running_tasks{$taskname};
      if($task->is_finished()) {
        delete $running_tasks{$taskname};
        $finished_tasks{$taskname} = $task;
        $task->get_TaskStatus->is_finished(1);
        $any_finished = 1;
      }

      last MAIN if($self->stop);
    }

    # If any tasks were identified as finished then we want to recalculate
    # which jobs are pending/finished (the finished state of one task can alter
    # the state of other tasks). This speeds up the determination
    # of which jobs for more equal time-sharing and faster restart of an
    # already running pipeline
    next MAIN if($any_finished);

    #
    # Give each running task a bit of time to create jobs
    #
    foreach my $taskname (keys %running_tasks) {
      my $task = $running_tasks{$taskname};
      my $subsystem = $self->_submission_systems->{$taskname};
      my $retcode = $task->run();
	
      if($retcode eq 'TASK_FAILED') {
        $self->warn("Task [$taskname] failure");
      } elsif ($retcode eq 'TASK_DONE') {
        $subsystem->flush($taskname);
      } elsif ($retcode ne 'TASK_OK') {
        $self->warn("Task [$taskname] returned unknown status $retcode");
      }

      last MAIN if($self->stop());
    }

    my $job_adaptor = $config->get_DBAdaptor->get_JobAdaptor();
    #
    # kill jobs that have been running for too long
    #
    my $timeout_list = 
      $job_adaptor->fetch_all_by_dbID_list($self->_timeout_list());
    $self->_timeout_list([]);
    foreach my $job (@$timeout_list) {			
      my $ss = $self->_submission_systems()->{$job->taskname()};
      $ss->kill($job);
    }

    #
    # retry failed jobs
    #
    my $failed_list = 
      $job_adaptor->fetch_all_by_dbID_list($self->_failed_list());
    $self->_failed_list([]);
    foreach my $job (@$failed_list) {
      my $taskname = $job->taskname();
      my $retry_count = $config->get_parameter($taskname, 'retries');
      if($job->retry_count() < $retry_count) {
        my $ss = $self->_submission_systems()->{$taskname};
        $job->retry_count($job->retry_count + 1);
        $job->set_current_status('RETRIED');
        $ss->submit($job);
      } else {
        $job->set_current_status('FATAL');
      }
    }

    sleep(1); #save some CPU when endlessly looping

  } #end of MAIN LOOP


  $config->get_DBAdaptor->db_handle()->{'InactiveDestroy'} = 0;
}


sub _tasks {
  my $self = shift;

  $self->{'_tasks'} ||= {};
  return $self->{'_tasks'};
}

sub _timeout_list {
  my $self = shift;
	
  $self->{'_timeout_list'} = shift if(@_);

  $self->{'_timeout_list'} ||= [];
  return $self->{'_timeout_list'};
}

sub _failed_list {
  my $self = shift;
	
  $self->{'_failed_list'} = shift if(@_);
  $self->{'_failed_list'} ||= [];
  return $self->{'_failed_list'};
}


sub _submission_systems {
  my $self = shift;

  $self->{'_submission_systems'} ||= {};
  return $self->{'_submission_systems'};
}



=head2 _update_task_status

  Arg [1]    : (optional) $just_started
               Should be set to true if the pipeline manager just restarted.
               If true this will delete all of the jobs of CREATED status
               from the databsae so that they may be recreated by the tasks
  Example    : none
  Description: Private method. Refreshes the status of running tasks by
               querying the pipeline database.  This method is also
               responsible for updating internal lists of jobs which have
               timed out or failed
  Returntype : none
  Exceptions : none
  Caller     : run() method

=cut

sub _update_task_status {
  my $self = shift;
  my $flush_created = shift;

  print STDERR "update task status begin\n";

  my $config = $self->get_Config;

  my $job_adaptor = $config->get_DBAdaptor()->get_JobAdaptor;

  print STDERR "DB status fetch begin\n";
  my $current_status_list = $job_adaptor->list_current_status();
  my $current_time = time();
  print STDERR "DB status fetch end\n";

  my %task_status;
  my %timeout_values;

  #
  # clean the current task status objects
  #
  foreach my $task (values %{$self->_tasks}) {
    $task->get_TaskStatus()->clean();
    $timeout_values{$task->name()} =
      $config->get_parameter($task->name(), 'timeout');
  }

  #
  # Place the jobs into task and status groups
  #

  my @delete_list;
  foreach my $current_status (@$current_status_list) {
    my ($job_id, $taskname, $input_id, $status, $timestamp,
       $stderr, $stdout) = @$current_status;

    $task_status{$taskname}->{'EXISTING'} ||= [];

    # when pipeline is restarted CREATED and RETRIED jobs need to be 
    # created again
    if($flush_created && ($status eq 'CREATED' || $status eq 'RETRIED')) {
      #delete the job from the database, don't and add it to the status
      push @delete_list, $job_id;
      next;
    }

    push(@{$task_status{$taskname}->{'EXISTING'}}, $input_id);

    #check if this is still running but has timed out
    if($status ne 'SUCCESSFUL' && $status ne 'FAILED'  &&
       $status ne 'FATAL'      && $status ne 'CREATED' &&
       $status ne 'KILLED'     && $status ne 'RETRIED' &&
       $current_time - $timestamp > $timeout_values{$taskname})
      {
        #timed out jobs need to go on list to be killed
        push @{$self->_timeout_list()}, $job_id;
      } else {

        if($status eq 'FAILED' || $status eq 'KILLED') {
          #failed jobs need to go on list to be retried
          push @{$self->_failed_list()}, $job_id;
        }

        $task_status{$taskname}->{$status} ||= [];
        push(@{$task_status{$taskname}->{$status}}, $input_id);
      }
  }

  #
  # delete 'CREATED' and 'RETRIED' jobs so they are recreated
  # on pipeline restart
  #
  if($flush_created && @delete_list) {
    $job_adaptor->remove_by_id_list(\@delete_list);
  }

  #
  # Update the task status objects
  #
  foreach my $taskname (keys %task_status) {
    my $ts = $self->_tasks()->{$taskname}->get_TaskStatus();
    if($task_status{$taskname}->{'CREATED'}) {
      $ts->add_created($task_status{$taskname}->{'CREATED'});
    }
    if($task_status{$taskname}->{'SUBMITTED'}) {
      $ts->add_submitted($task_status{$taskname}->{'SUBMITTED'});
    }
    if($task_status{$taskname}->{'READING'}) {
      $ts->add_reading($task_status{$taskname}->{'READING'});
    }
    if($task_status{$taskname}->{'WRITING'}) {
      $ts->add_writing($task_status{$taskname}->{'WRITING'});
    }
    if($task_status{$taskname}->{'RUNNING'}) {
      $ts->add_running($task_status{$taskname}->{'RUNNING'});
    }
    if($task_status{$taskname}->{'SUCCESSFUL'}) {
      $ts->add_successful($task_status{$taskname}->{'SUCCESSFUL'});
    }
    if($task_status{$taskname}->{'FAILED'}) {
      $ts->add_failed($task_status{$taskname}->{'FAILED'});
    }
    if($task_status{$taskname}->{'FATAL'}) {
      $ts->add_fatal($task_status{$taskname}->{'FATAL'});
    }
    if($task_status{$taskname}->{'RETRIED'}) {
      $ts->add_retried($task_status{$taskname}->{'RETRIED'});
    }
    if($task_status{$taskname}->{'KILLED'}) {
      $ts->add_killed($task_status{$taskname}->{'KILLED'});
    }
    if($task_status{$taskname}->{'EXISTING'}) {
      $ts->add_existing($task_status{$taskname}->{'EXISTING'});
    }

    print STDERR "[$taskname]:\n",$ts->status_report,"\n";
  }

  print STDERR "update task status complete\n";
}



=head2 create_Job

  Arg [1]    : string $taskname
               The name of the task submitting this job.
  Arg [2]    : string $modulename
               The name of the module that does the work for the jobs.
               The module needs to implement the methods fetch_input(), run()
               and write_output()
  Arg [3]    : string $input_id
               The input id associated with this module
  Arg [4]    : string $parms
               A parameter string specific to the job which is being submitted
  Example    :
    $pl_manager->create_Job('RepeatMasker',
                           'Bio::EnsEMBL::Pipeline::RunnnableDB::RepeatMasker',
                           '124314',
                           '-threshold 90 -v');
  Description: Creates and submits a new pipeline job.  Tasks generally create
               jobs to be run using this method or create_Jobs.  Note that
               this method will allow jobs with the same input_id to be
               created.
  Returntype : boolean - true on success, false on failure
  Exceptions : none
  Caller     : Tasks

=cut

sub create_Job {
  my ($self, $taskname, $modulename, $input_id, $parms) = @_;
  my $ssystem = $self->_submission_systems()->{$taskname};
  my $job = $ssystem->create_Job($taskname, $modulename, $input_id, $parms);

  if(!$job){
    #too many pending jobs already
    return 0;
  }

  #add the id to the taskstatus as existing and created...
  my $ts = $self->get_TaskStatus($taskname);

  my $idset = Bio::EnsEMBL::Pipeline::IDSet->new(-ID_LIST => [$input_id]);
  $ts->add_existing($idset);
  $ts->add_created($idset);

  $ssystem->submit($job);
  return 1;
}

	


=head2 create_Jobs

  Arg [1]    : string $taskname
               The name of the task submitting these jobs.
  Arg [2]    : string $modulename
               The name of the module that does the work for the jobs.
               The module needs to implement the methods fetch_input(), run()
               and write_output()
  Arg [3]    : Bio::EnsEMBL::Pipeline::IDSet
               A set of input ids for the jobs to be submitted
  Arg [4]    : string $parms
               A parameter string specific to the jobs being submitted
  Example    : $pl_manager->create_Jobs('Genscan',
                         'Bio::EnsEMBL::Pipeline::RunnnableDB::RepeatMasker',
                         $id_set,
                         'vertrna -subopt 90');
  Description: Creates and submits a group of pipeline jobs.  Tasks generally
               create jobs to be run using this method or create_Job.
               Note that this method will filter out all jobs which have
               input_ids matching jobs that have already been created.
  Returntype : boolean - true on success, false on failure/partial failure
  Exceptions : none
  Caller     : Tasks

=cut

sub create_Jobs {
  my ($self, $taskname, $modulename, $id_set, $parms) = @_;

  my $task = $self->_tasks()->{$taskname};

  my $ts = $task->get_TaskStatus();

  # discard ids that have already been created
  $id_set = $id_set->not($ts->get_existing());

  #
  # submit the jobs
  #
  foreach my $id (@{$id_set->ID_list}) {
    my $job = $self->create_Job($taskname, $modulename, $id, $parms);
    #if there are too many pending jobs this one won't be
    return 0 if(!$job);
  }

  return 1;
}


1;
