=head1 NAME - Bio::EnsEMBL::Pipeline::GeneComparison::GeneComparison

=head1 DESCRIPTION

Perl Class for comparison of two sets of genes.
It can read two references to two arrays of genes, e.g. EnsEMBL built genes and human annotated genes,
and it compares them using different methods (see Synopsis).

The object must be created passing two arrayref with the list of genes to be comapred.

Each GeneComparison object can contain data fields specifying the arrays of genes to be compared.
There are also data fields in the form of two arrays, which contain 
the gene types present in those both gene arrays.

=head1 SYNOPSIS

  my $gene_comparison = Bio::EnsEMBL::Pipeline::GeneComparison::GeneComparison->new(\@genes1,\@genes2);

  my @clusters = $gene_comparison->cluster_Genes;

get the list of unmatched genes, this returns two array references of GeneCluster objects as well, 
but only containing the unmatched ones:

  my ($ens_unmatched,$hum_unmatched) = $gene_comparison->get_unmatched_Genes;

get the list of fragmented genes:

  my @fragmented = $gene_comparison->get_fragmented_Genes (@clusters);

cluster the transcripts using the gene clusters obtained above
(first cluster all genes and then cluster the transcripts within each gene):
   
  my @transcript_clusters = $gene_comparison->cluster_Transcripts_by_Gene(@clusters);

Also, one can cluster the transcripts of the genes in annotation_Genes() and prediction_Genes() directly
(cluster all transcripts without going through gene-clustering)

  my @same_transcript_clusters = $gene_comparison->cluster_Transcripts;

One can get the number of exons per percentage overlap using whole exons
  
  my %statistics = $gene_comparison->get_Exon_Statistics;

Or only coding exons

  my %coding_statistics =  $gene_comparison->get_Coding_Exon_Statistics;

The hashes hold the number of occurences as values and integer percentage overlap as keys
and can be used to produce a histogram:
 
  for (my $i=1; $i<= 100; $i++){
    if ( $statistics{$i} ){
      print $i." :\t".$statistics{$i}."\n";
    }
    else{
      print $i." :\n";
    }
  }

for more info about how to use it look in the example script
...ensembl/misc-scripts/utilities/gene_comparison_script.pl

=head1 CONTACT

eae@sanger.ac.uk

=cut

# Let the code begin ...

package Bio::EnsEMBL::Pipeline::GeneComparison::GeneComparison;

use vars qw(@ISA);
use strict;

use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Pipeline::GeneComparison::GeneCluster;
use Bio::EnsEMBL::Pipeline::GeneComparison::TranscriptCluster;
use Bio::Root::RootI;
use Bio::EnsEMBL::Pipeline::GeneComparison::GeneCompConf;

@ISA = qw(Bio::Root::RootI);

####################################################################################

=head2 new()

the new() method accepts two array references

=cut

sub new {
  
  my ($class,@args) = @_;
  # as convention, we put first the annotated (or benchmark) genes and second the predicted genes
  # Anyway, the comparisons are made from the gene_array2 with respect to the gene_array1
  # so 'missing_exons' means when gene_array2 misses exons with respect to gene_array1 and
  # overpredicted exons means when gene_array2 have exons in excess with respect to the gene_array1

  if (ref($class)){
    $class = ref($class);
  }
  my $self = {};
  bless($self,$class);
  
  my ( $annotation_db, $prediction_db, $annotation_genes, $prediction_genes, $input_id, $gff_file ) = 
    $self->_rearrange([qw(ANNOTATION_DB
			  PREDICTION_DB
			  ANNOTATION_GENES
			  PREDICTION_GENES
			  INPUT_ID
			  GFF_FILE)],
		      @args);
  unless (  $annotation_db && $prediction_db && $annotation_genes && $prediction_genes && $input_id ){
    $self->throw("need to specify all these values:\n
     annotation_db: $annotation_db\n
     prediction_db: $prediction_db\n
  annotation_genes: $annotation_genes\n
  prediction_genes: $prediction_genes\n 
         $input_id: $input_id\n");
  }
  
  $self->annotation_db($annotation_db);
  $self->prediction_db($prediction_db);
  $self->annotation_Genes(@$annotation_genes);
  $self->prediction_Genes(@$prediction_genes);
  $self->input_id($input_id);

  if ( $gff_file ){
    $self->gff_file($gff_file);
  }

  $self->{'_unclustered_genes'}= [];
  $self->{'_gene_clusters'}= [];

  if ( $self->annotation_Genes && $self->prediction_Genes ){
    
    my %ann_types;
    foreach my $gene ( $self->annotation_Genes ){
      $ann_types{$gene->type}=1;
    }
    foreach my $k ( keys(%ann_types) ){            
      push( @{ $self->{'_annotation_types'} }, $k);
    }

    my %pred_types;
    foreach my $gene ( $self->prediction_Genes ){
      $pred_types{$gene->type}=1;
    }
    foreach my $k ( keys(%pred_types) ){           
      push( @{ $self->{'_prediction_types'} }, $k);
    }
  }
  else{
    $self->throw( "Can't create a Bio::EnsEMBL::Pipeline::GeneComparison::GeneComparison object without passing in two gene arrayref");
  }
  if ( scalar( $self->annotation_Genes ) == 0 || scalar( $self->prediction_Genes ) == 0 ){
    $self->throw( "At least one of the lists of genes to compare is empty. Cannot create a GeneComparison object");
  }
  return $self;
}
######################################################################################

sub annotation_Genes {
  my ($self,@genes) = @_;
  if ( @genes ){
    push ( @{ $self->{'_annotation_genes'} }, @genes );
  }
  return @{ $self->{'_annotation_genes'} };
}

######################################################################################

sub prediction_Genes {
  my ($self,@genes) = @_;
  if ( @genes ){
    push ( @{ $self->{'_prediction_genes'} }, @genes );
  }
  return @{ $self->{'_prediction_genes'} };
}

######################################################################################

=head2 gene_Types()

this function sets or returns two arrayref with the types of the genes to be compared.
All the comparisons are made from the gene_array1 with respect to the gene_array2.

=cut

sub gene_Types {
   my ($self,$ann_type,$pred_type) = @_;
   if ( $ann_type && $pred_type ){
     $self->{'_annotation_types'} = $ann_type; 
     $self->{'_prediction_types'} = $pred_type;
   }
   return ( $self->{'_annotation_types'}, $self->{'_prediction_types'} );
}

######################################################################################

=head2 cluster_Genes

  This method takes an array of genes and cluster them
  according to their exon overlap. As a default it takes the genes stored in the GeneComparison object 
  as data fields (or attributes) '_gene_array1' and '_gene_array2'. It can also accept instead as argument
  an array of genes to be clustered, but then information about their gene-type is lost (to be solved). 
  This method returns an array of GeneCluster objects.

=cut

sub cluster_Genes {

  my ($self) = @_;
  my @genes = ( $self->annotation_Genes, $self->prediction_Genes);
  
  #### first sort the genes by the left-most position coordinate ####
  my %start_table;
  my $i=0;
  foreach my $gene (@genes){
    $start_table{$i}=_get_start_of_Gene($gene);
    $i++;
  }
  my @sorted_genes=();
  foreach my $k ( sort { $start_table{$a} <=> $start_table{$b} } keys %start_table ){
    push (@sorted_genes, $genes[$k]);
  }

  print "Clustering ".scalar( @sorted_genes )." genes...\n";
  #my $label=1;
  #foreach my $gene (@sorted_genes){
  #  print $label." gene ".$gene->stable_id."\t\t"._get_start_of_Gene($gene)." "._get_strand_of_Gene($gene)."\n";
  #  $label++;
  #}
  my $found;
  my $time1=time();

##### old clustering algorithm ###########################################

#  my @clusters=(); # this will hold an array of GeneCluster objects
#  my $lookups=0;
#  my $count = 1;
#  my $new_cluster_count=1;
#  my $jumpy=0;

#  foreach my $gene (@sorted_genes){
#    print STDERR $count." gene ".$gene->stable_id." being located...";
#    $count++;
#    $found=0;
#    my $cluster_count=1;
#  LOOP:
#    foreach my $cluster (@clusters){
#      foreach my $gene_in_cluster ( $cluster->get_Genes ){  # read all  genes from GeneCluster object
#	$lookups++;
#        if ( _compare_Genes($gene,$gene_in_cluster) ){
#          print STDERR "put in cluster ".$cluster_count."\n";
#	  if ( $cluster_count != ($new_cluster_count-1)  ){
#	    print STDERR "\nONE JUMPING AROUND!!\n\n";
#	    $jumpy++;
#	  }
	  
#	  $cluster->put_Genes($gene);                       # put gene into GeneCluster object
#          $found=1;
#          last LOOP;
#        }
#      }
#      $cluster_count++;
#    }
#    if ($found==0){
#      my $new_cluster=Bio::EnsEMBL::Pipeline::GeneComparison::GeneCluster->new();   # create a GeneCluser object
#      print STDERR "put in new cluster [".$new_cluster_count."]\n";
#      $new_cluster_count++;
#      $new_cluster->gene_Types($self->gene_Types);
#      $new_cluster->put_Genes($gene);
#      push(@clusters,$new_cluster);
#    }
#  }
#  my $time2 = time();
#  print STDERR "\ntime for clustering: ".($time2-$time1)."\n";
#  print STDERR "number of lookups: ".$lookups."\n";
#  print STDERR "number of jumpies: ".$jumpy."\n\n";
#  return @clusters;
#  # put all unclustered genes (annotated and predicted) into one separate array
#  $self->flush_gene_Clusters;
#  foreach my $cl (@clusters){
#    if ( $cl->get_Gene_Count == 1 ){
#      $self->unclustered_Genes($cl); # this push the cluster into array @{ $self->{'_unclustered_genes'} }
#    }
#    else{
#      $self->clusters( $cl );
#    }
#  }  
#  return $self->clusters;

#########################################################################

  #### new clustering algorithm, faster than the old one ####
  
  # create a new cluster 
  my $cluster=Bio::EnsEMBL::Pipeline::GeneComparison::GeneCluster->new();
  my $cluster_count = 1;
  my @clusters;

  # pass in the types we're using
  my ($types1,$types2) = $self->gene_Types;
  $cluster->gene_Types($types1,$types2);

  # put the first gene into these cluster
  $cluster->put_Genes( $sorted_genes[0] );
  push (@clusters, $cluster);
  $self->gene_Clusters($cluster);
  
  # loop over the rest of the genes
 LOOP1:
  for (my $c=1; $c<=$#sorted_genes; $c++){
    $found=0;
  LOOP:
    foreach my $gene_in_cluster ( $cluster->get_Genes ){       
      if ( _compare_Genes( $sorted_genes[$c], $gene_in_cluster ) ){	
	$cluster->put_Genes( $sorted_genes[$c] );                       
	$found=1;
	next LOOP1;
      }
    }
    # if not in this cluster compare to the ($limit) previous clusters

    my $limit = 14;
    if ( $found == 0 && $cluster_count > 1 ){
      my $lookup = 1;
      while ( !($cluster_count <= $lookup) && !($lookup > $limit) ){ 
	#print STDERR "cluster_count: $cluster_count, looking at ".($cluster_count - $lookup)."\n";
	my $previous_cluster = $clusters[ $cluster_count - 1 - $lookup ];
	foreach my $gene_in_cluster ( $previous_cluster->get_Genes ){
	  if ( _compare_Genes( $sorted_genes[$c], $gene_in_cluster ) ){	
	    $previous_cluster->put_Genes( $sorted_genes[$c] );                       
	    $found=1;
	    next LOOP1;
	  }
	}
	$lookup++;
      }
    }
    if ($found==0){  # if not-clustered create a new GeneCluser
      $cluster = new Bio::EnsEMBL::Pipeline::GeneComparison::GeneCluster; 
      $cluster->gene_Types($types1,$types2);
      $cluster->put_Genes( $sorted_genes[$c] );
      $cluster_count++;
      push( @clusters, $cluster );
      $self->gene_Clusters( $cluster );
    }
  }
  # put all unclustered genes (annotated and predicted) into one separate array
  my $time2 = time();
  print STDERR "time for clustering: ".($time2-$time1)."\n";
  my @new_clusters;  
  foreach my $cl ($self->gene_Clusters){
    if ( $cl->get_Gene_Count == 1 ){
      $self->unclustered_Genes($cl); # this push the cluster into array @{ $self->{'_unclustered_genes'} }
    }
    else{
      push( @new_clusters, $cl );
    }
  }
  $self->flush_gene_Clusters;
  $self->gene_Clusters(@new_clusters);
  #my @unclustered = $self->unclustered_Genes;
  return @new_clusters;
}
 
######################################################################################

=head2 pair_Genes

  This method creates one GeneCluster object per benchmark gene and then PAIR them with predicted genes
  according to their exon overlap. As a default it takes the genes stored in the GeneComparison object 
  as data fields. It can also accept instead as argument
  an array of genes to be paired, but then information about their gene-type is lost (to be solved). 
  The result is put into $self->{'_gene_clusters'} and $self->{'_unclustered_genes'} 
  
=cut

sub pair_Genes {

  my ($self) = @_;
  my (@genes1,@genes2);

  @genes1 =  $self->annotated_Genes;
  @genes2 =  $self->predciont_Genes;

  #### first sort the genes by the left-most position coordinate ####
  my %start_table;
  my $i=0;
  foreach my $gene (@genes1){
    $start_table{$i}=_get_start_of_Gene($gene);
    $i++;
  }
  my @sorted_genes=();
  foreach my $k ( sort { $start_table{$a} <=> $start_table{$b} } keys %start_table ){
    push (@sorted_genes, $genes1[$k]);
  }
  @genes1 = @sorted_genes;
  
  %start_table = (); 
  $i=0;
  foreach my $gene (@genes2){
    $start_table{$i}=_get_start_of_Gene($gene);
    $i++;
  }
  @sorted_genes=();
  foreach my $k ( sort { $start_table{$a} <=> $start_table{$b} } keys %start_table ){
    push (@sorted_genes, $genes2[$k]);
  }
  @genes2 = @sorted_genes;

  #### PAIR the genes ####
  #### creating a new cluster for each gene in the benchmark set ### 

  foreach my $gene (@genes2){
    # create a GeneCluser object
    my $cluster=Bio::EnsEMBL::Pipeline::GeneComparison::GeneCluster->new();
    my ($type1,$type2) = $self->gene_Types;
    $cluster->gene_Types($type1,$type2);
    $cluster->put($gene);
    $self->gene_Clusters($cluster);
  }
  
 GENE:   while (@genes1){
    my $gene = shift @genes1;
    
    foreach my $cluster ($self->gene_Clusters){	
      my $gene_in_cluster = $cluster->get_first_Gene ;  # read first gene from GeneCluster object
      
      if ( _compare_Genes($gene,$gene_in_cluster) ){	
	$cluster->put_Genes($gene);       # put gene into GeneCluster object
	next GENE;
      }
    }
    #### an arbitary cluster containing the set of predicted genes that do not overlap with any from the 
    #### benchmark set
    my $unclustered = new Bio::EnsEMBL::Pipeline::GeneComparison::GeneCluster;
    $unclustered->gene_Types($self->gene_Types);
    $unclustered->put_Genes($gene);  # NOTE: this holds unclustered predicted genes, but does not
                                     # know about unpaired benchmark genes
    
    $self->unclustered_Genes($unclustered); # push the cluster into an array	 
  }
  return 1;
}
#########################################################################

=head2 _get_start_of_Gene()

  function to get the left-most coordinate of the exons of the gene (start position of a gene).
  For genes in the strand 1 it reads the gene object and it returns the start position of the 
  first exon. For genes in the strand -1 it picks the last exon and reads the start position; this
  is not the proper start of the gene but it is the left-most coordinate.

=cut

sub _get_start_of_Gene {
  my $gene = shift @_;
  my @exons = $gene->get_all_Exons;
  my $st;
  if ($exons[0]->strand == 1) {
    @exons = sort {$a->start <=> $b->start} @exons;
    $st = $exons[0]->start;
  } else {
    @exons = sort {$b->start <=> $a->start} @exons;
    $st = $exons[$#exons]->start;
  }
  return $st;
}

##########################################################################

=head2 _get_strand_of_Gene()

=cut

sub _get_strand_of_Gene {
  my $gene = shift @_;
  my @exons = $gene->get_all_Exons;
  
  if ($exons[0]->strand == 1) {
    return 1;
  }
  else{
    return -1;
  }
  return 0;
}



####################################################################################

=head2 cluster_Transcripts_by_Gene()

it first clusters all genes using cluster_Genes and then cluster the transcripts within each gene
cluster. If one has already made a gene-clustering, one can pass the array of clusters
to cluster_Transcripts_by_Gene() to avoid repetition of work

See cluster_Transcripts for a different way of clustering transcripts.

=cut

sub cluster_Transcripts_by_Gene {
  my ($self,$array) = @_;
  my @gene_clusters;    
  my @transcript_clusters;
  if ($array){
    push(@gene_clusters,@$array);
  }
  else{
    @gene_clusters = $self->cluster_Genes;
  }
  foreach my $cluster (@gene_clusters){
    
    my @transcripts;   
    foreach my $gene ( $cluster->get_Genes ){
      push ( @transcripts, $gene->each_Transcript );
    }
    push ( @transcript_clusters, $self->cluster_Transcripts(@transcripts) );
    # we pass the array of transcripts to be clustered to the method cluster_Transcripts
  }
  return @transcript_clusters;
}

####################################################################################

=head2 cluster_Transcripts()

  This method cluster all the transcripts in the gene arrays passed to the GeneComparison constructor new().
  It also accepts an array of transcripts to be clustered. The clustering is done according to exon
  overlaps, which is implemented in the function _compare_Transripts.
  This method returns an array of TranscriptCluster objects.

=cut
  
sub cluster_Transcripts {
  my ($self,@transcripts) = @_;
 
  unless ( @transcripts ){                        
    my @genes = ( $self->annotation_Genes, $self->prediction_Genes );
    foreach my $gene (@genes){
      my @more_transcripts = $gene->each_Transcript;
      push ( @transcripts, @more_transcripts );
    }
  }
  # we do the clustering with the array @transcripts like we do with genes
  
  # first sort the transcripts by their start position coordinate
  my %start_table;
  my $i=0;
  foreach my $transcript (@transcripts){
    my $start;
    my $seqname;
    my @exons = $transcript->get_all_Exons;
    @exons = sort { $a->start <=> $b->start } @exons;
    if ( $exons[0]->start > $exons[0]->end){
      $start = $exons[0]->end;
    }
    else{
      $start = $exons[0]->start;
    }
    $start = $transcript->start_exon->start;
    $start_table{$i} = $start;
    $i++;
    
    # if some exons in the transcript fall outside the vc, they will not be converted to vc coordinates
    foreach my $exon (@exons){
      unless ( $seqname ){
	$seqname = $exon->seqname;
      }
      unless ($seqname eq $exon->seqname){
	my $label;
	if ($transcript->stable_id){
	  $label = $transcript->stable_id;
	}
	elsif ( $transcript->dbID ){
	  $label = $transcript->dbID;
	}
	else{
	  $label = "unknown";
	}
	
	$self->warn("transcript (ID: ".$label.") is partly outside the contig");
	last;
      }
    }
  }
  my @sorted_transcripts=();
  foreach my $pos ( sort { $start_table{$a} <=> $start_table{$b} } keys %start_table ){
    push (@sorted_transcripts, $transcripts[$pos]);
  }
  @transcripts = @sorted_transcripts;
#  # test
#  foreach my $tran (@transcripts){
#    print STDERR "\ntranscript: ".$tran->stable_id."internal_id: ".$tran->dbID."\n";
#    foreach my $exon ($tran->get_all_Exons){
#      print STDERR $exon->seqname." ".$exon->start.":".$exon->end."\n";
#    }
#    print STDERR "\n";
#  }
  my $time1 = time();
  my @clusters;

  # create a new cluster 
  my $cluster=Bio::EnsEMBL::Pipeline::GeneComparison::TranscriptCluster->new();
  my $cluster_count = 1;

  # put the first transcript into these cluster
  $cluster->put_Transcripts( $sorted_transcripts[0] );
  push( @clusters, $cluster );
  # $self->transcript_Clusters($cluster);
  
  # loop over the rest of the genes
 LOOP1:
  for (my $c=1; $c<=$#sorted_transcripts; $c++){
    my $found=0;
  LOOP:
    foreach my $t_in_cluster ( $cluster->get_Transcripts){       
      if ( _compare_Transcripts( $sorted_transcripts[$c], $t_in_cluster ) ){	
	$cluster->put_Transcripts( $sorted_transcripts[$c] );                       
	$found=1;
	next LOOP1;
      }
    }
    # if not in this cluster compare to the previous clusters:
    
    # to set a limit in the number of previous cluster to look up
    # set for example my $limit = 6; and then add to the while condition :
    # while ( !(...) &&  !($lookup > $limit) ){ 
    
    my $limit = 14;
    if ( $found == 0 && $cluster_count > 1 ){
      my $lookup = 1;
      while ( !($cluster_count <= $lookup )  &&  !($lookup > $limit)  ){ 
	#print STDERR "cluster_count: $cluster_count, looking at ".($cluster_count - $lookup)."\n";
	my $previous_cluster = $clusters[ $cluster_count - 1 - $lookup ];
	foreach my $t_in_cluster ( $previous_cluster->get_Transcripts ){
	  if ( _compare_Transcripts( $sorted_transcripts[$c], $t_in_cluster ) ){	
	    $previous_cluster->put_Transcripts( $sorted_transcripts[$c] );                       
	    $found=1;
	    next LOOP1;
	  }
	}
	$lookup++;
      }
    }
    # if not-clustered create a new TranscriptCluser
    if ($found==0){  
      $cluster = new Bio::EnsEMBL::Pipeline::GeneComparison::TranscriptCluster; 
      $cluster->put_Transcripts( $sorted_transcripts[$c] );
      $cluster_count++;
      push( @clusters, $cluster );
      # $self->transcript_Clusters( $cluster );
    }
  }
  my $time2 = time();
  my $time = $time2-$time1;
  print STDERR "clustering time: ".$time."\n";
  return @clusters;
}


####################################################################################

sub compare_CDS{
  my ($self,$clusters) = @_;
  my @total_ann_unpaired;
  my @total_pred_unpaired;
  my @total_ann_doubled;
  my @total_pred_doubled;
  my $pairs_count = 0;
  my $same_start = 0;
  my $same_end   = 0;
  my %diff_start;
  my %diff_end;

 CLUSTER:
  foreach my $gene_cluster (@$clusters){
    my ( $pairs, $ann_unpaired, $pred_unpaired ) = $gene_cluster->pair_Transcripts;
    my @pairs = @{ $pairs };
    
    #my @ann_unpaired;
    #my @pred_unpaired;
    #my @ann_doubled;
    #my @pred_doubled;
    #push ( @ann_unpaired , @{ $ann_unpaired }  );
    #push ( @pred_unpaired, @{ $pred_unpaired } );
    #push ( @ann_doubled  , @{ $ann_doubled }   );    
    #push ( @pred_doubled , @{ $pred_doubled }  );
    
    #push ( @total_ann_doubled  , @ann_doubled   );
    #push ( @total_pred_doubled , @pred_doubled  );
    push ( @total_ann_unpaired , @$ann_unpaired  ); 
    push ( @total_pred_unpaired, @$pred_unpaired );

    # for each pair we keep track of the exon comparison
 
   PAIR:
    foreach my $pair ( @pairs ){
      $pairs_count++;
       my ($prediction,$annotation) = $pair->get_Transcripts;
    
      my $t_prediction = $prediction->translation;
      my $t_annotation = $annotation->translation;
      unless ( $t_prediction && $t_annotation ){
	print STDERR "one of the transcripts has no translation\n";
	next PAIR;
      }
      
      my $t_start_pred = $t_prediction->start;
      my $t_end_pred   = $t_prediction->end;
      
      my $t_start_ann  = $t_annotation->start;
      my $t_end_ann    = $t_annotation->end;
      
      if ( $t_start_pred == $t_start_ann ){
	$same_start++;
      }
      else{
	my $diff = int( abs( $t_start_pred - $t_start_ann )/10 );
	$diff_start{ $diff }++;
      }
      
      if ( $t_end_pred == $t_end_ann ){
	$same_end++;
      }
      else{
	my $diff = int( abs( $t_end_pred - $t_end_ann )/10 );
	$diff_end{ $diff }++;
      }
    } # end of PAIR
  }   # end of CLUSTER
  
  print STDERR "Number of compared transcript-pairs    : $pairs_count\n";
  print STDERR "Number of coinciding translation starts: $same_start\n";
  print STDERR "Number of coinciding translation end   : $same_end\n";
  print STDERR "distribution of differences for start:\n";
  foreach my $k ( sort{ $a <=> $b } keys( %diff_start ) ){
    print STDERR "diff [".($k*10)." - ".(($k+1)*10)."] --> $diff_start{$k} times\n";
  }
  print STDERR "distribution of differences for end:\n";
  foreach my $k ( sort{ $a <=> $b } keys( %diff_end   ) ){
    print STDERR "diff [".($k*10)." - ".(($k+1)*10)."] --> $diff_end{$k} times\n";
  }
}

####################################################################################

sub compare_Translations{
  my ($self,$clusters) = @_;
  my @total_ann_unpaired;
  my @total_pred_unpaired;
  my @total_ann_doubled;
  my @total_pred_doubled;
  my $pairs_count = 0;
  my %diff_relative_to_annotation;

  my $exact_match = 0;
  my $ann_embedded_in_pred = 0;
  my $pred_embedded_in_ann = 0;

 CLUSTER:
  foreach my $gene_cluster (@$clusters){
    my ( $pairs, $ann_unpaired, $pred_unpaired, $ann_doubled, $pred_doubled) = $gene_cluster->pair_Transcripts;
    my @pairs = @{ $pairs };
    
    if ( $ann_unpaired ){
       push ( @total_ann_unpaired , @{ $ann_unpaired }  );
    }
    if ( $pred_unpaired ){
       push ( @total_pred_unpaired, @{ $pred_unpaired } );
    }
    #push ( @ann_doubled  , @{ $ann_doubled }   );    
    #push ( @pred_doubled , @{ $pred_doubled }  );
    
    #push ( @total_ann_doubled  , @ann_doubled   );
    #push ( @total_pred_doubled , @pred_doubled  );
    #push ( @total_ann_unpaired , @ann_unpaired  ); 
    #push ( @total_pred_unpaired, @pred_unpaired );

    # for each pair we keep track of the exon comparison
 
   PAIR:
    foreach my $pair ( @pairs ){
      $pairs_count++;
       my ($prediction,$annotation) = $pair->get_Transcripts;
    
      my $pred_translation_seq;
      my $ann_translation_seq;
      my $pred_peptide_length;
      my $ann_peptide_length;
      my $pred_peptide_seq;
      my $ann_peptide_seq;

    #my $pred_translation = $prediction->translation;
    #my $ann_translation  = $annotation->translation;
    
    eval{  
      $pred_translation_seq = $prediction->translate;
      $pred_peptide_seq = $pred_translation_seq->seq; 
      $pred_peptide_length  = $pred_translation_seq->length;
      print STDERR "prediction translation_length: ".$pred_peptide_length."\n";
    };       
    if ($@){
      print STDERR "problems getting translation for prediction\n";
    }    
    eval{
      $ann_translation_seq  = $annotation->translate;
      $ann_peptide_seq  = $ann_translation_seq ->seq; 
      $ann_peptide_length   = $ann_translation_seq->length;
      print STDERR "annotation translation_length: ".$ann_peptide_length ."\n";
    };
    if ($@){
      print STDERR "problems getting translation for annotation\n";
    }

    if ( $pred_peptide_length && $ann_peptide_length ){
       my $difference = int( ($ann_peptide_length - $pred_peptide_length)/10 );
       $diff_relative_to_annotation{ $difference }++;
    }
        
    my $goback = 0; 
    unless ( $pred_peptide_seq ){
      print STDERR "prediction has no translation\n";
      $goback = 1;
    }
    unless ( $ann_peptide_seq ){
      print STDERR "annotation has no translation\n";
      $goback = 1;
    }
    if ( $goback ){
      next PAIR;
    }
      # only store the genes whose translation has no stop codons
    
    if ( $pred_peptide_seq && $ann_peptide_seq){
     if ( $pred_peptide_seq =~ /\*/ ){
	 print STDERR "prediction peptide has STOP codon\n";
     }
     if ( $ann_peptide_seq  =~ /\*/ ){
	 print STDERR "annotation peptide has STOP codon\n";
     }
     if ( $ann_peptide_seq eq $pred_peptide_seq ){
         print STDERR "Identical translation\n";
         #print STDERR "If you don't believe it...\n";
         #print STDERR "Annotation: $ann_peptide_seq\n";
         #print STDERR "Prediction: $pred_peptide_seq\n";
         $exact_match++;
     }
     elsif ( $ann_peptide_seq =~ /$pred_peptide_seq/ ){
         print STDERR "prediction is a truncated peptide of the annotation\n";
         $pred_embedded_in_ann++;
     }
     elsif ( $pred_peptide_seq = ~ /$ann_peptide_seq/ ){
         print STDERR "annotation is a truncated peptide of the prediction\n";
         $ann_embedded_in_pred++;
     }
     else{
      
         # the only thing left to do would be to try to align them and get a similarity score
     }
     print STDERR "\n";
    }  
    } # end of PAIR
  }   # end of CLUSTER
  
  print STDERR "Number of compared transcript-pairs    : $pairs_count\n";
  print STDERR "prediction transcripts unpaired        : ".scalar(@total_pred_unpaired)."\n";
  print STDERR "annotation transcripts unpaired        : ".scalar(@total_ann_unpaired)."\n";
  print STDERR "Number of exact peptide matches        : ".$exact_match."\n";
  print STDERR "     annotation embedded in prediction : ".$ann_embedded_in_pred."\n";
  print STDERR "     prediction embedded in annotation : ".$pred_embedded_in_ann."\n";
  print STDERR "Difference in translation length relative to annotation:\n";
  foreach my $key ( sort{ $a <=> $b } keys( %diff_relative_to_annotation ) ){
    print STDERR "interval (".($key*10).",".(($key+1)*10).") --> ".$diff_relative_to_annotation{ $key }."\n";
  }
  
 
  
}

####################################################################################

=head2 compare_Exons()

  Title   : compare_Exons()
  Usage   : my %stats = $gene_comparison->compare_Exons(\@gene_clusters);
  Function: This method takes an array of GeneCluster objects, pairs up all the transcripts in each 
            cluster and then go through each transcript pair trying to match the exons. 
            It keeps track of the exons present in the annotation_genes passed to new() that are missing in
            the corresponding transcript of prediction_genes, also of those exons that are overpredicted in
            in prediction_genes with respect to annotation_genes. It also gives a generic exon_mismatch result.
            Setting the flag 'coding' in the arguments we can compare the CDSs
  
  Returns : a hash with the arrays of transcript pairs (each pair being a Bio::EnsEMBL::Pipeline::GeneComparison::TranscriptCluster) as values, and the number of missing exons as keys, useful to make a histogram
  Args    : an arrayref of Bio::EnsEMBL::Pipeline::GeneComparison::GeneCluster objects 

=cut
  
sub compare_Exons{
  my ($self,$clusters,$coding,$verbose) = @_;

  my $global_count = 1;
  my @pairs_missing;                # holds the transcript pairs that have one or more exons missing
  my $pairs_count;                  # this will count the total number of pairs compared
  my $total_missing_exon_count = 0; # counts the number of overpredicted exons
  my $total_over_exon_count    = 0; # same for overpredictions
  my $total_exon_mismatches    = 0; # includes the above two cases
 
  my %over_exon_position;           # keeps track of the positions of the exons
  my %missing_exon_position;        # keeps track of the positions of the exons
  
  my $total_prediction_matched = 0; # numerator in the computation of the sensitivity/specificity
                                    #  ( = TruePositive )

  my $total_annotation_length  = 0; # denominator in the computation of the sensitivity
                                    #  ( = TruePositive + FalseNegative )

  my $total_prediction_length  = 0; # denominator in the computation of the specificity
                                    #  ( = TruePositive + FalsePositive )

  if ( !defined( $clusters ) ){
    $self->throw( "Must pass an arrayref of Bio::EnsEMBL::Pipeline::GeneComparison::GeneCluster objects");
  } 
  if ( !$$clusters[0]->isa( 'Bio::EnsEMBL::Pipeline::GeneComparison::GeneCluster' ) ){
    $self->throw( "Can't process a [$$clusters[0]], you must pass a Bio::EnsEMBL::Pipeline::GeneComparison::GeneCluster" );
  }
  
  # warn about the comparison that is about to happen
  my ($annotation_types,$prediction_types) = $$clusters[0]->gene_Types;
  my ($message1,$message2) = ( '','');
  my $messageA = "Comparing exons in gene-types: ";
  foreach my $type ( @$annotation_types ){
    $message1 .= $type.", ";
  }
  my $messageB = " with exons in gene-types: ";
  foreach my $type ( @$prediction_types ){
    $message2 .= $type.", ";
  }
  print STDERR $messageA.$message1.$messageB.$message2."...\n";

  my %missing;       # this hash holds the transcript pairs with one, two, etc... missing exons
  my %overpredicted; # similarly for overpredicted exons
  my %mismatches;    # includes all of the above

  my @total_ann_unpaired;
  my @total_pred_unpaired;
  my @total_ann_doubled;
  my @total_pred_doubled;
  my $exact_matches   = 0; # counts the number of exact matching exons
  my $exon_pair_count = 0; # counts the number of exons

  my $cluster_count   = 1;

  # we check for missing exons in genes of type $type2 in each gene cluster
 GENE:
  foreach my $gene_cluster (@$clusters){
    print STDERR "\nIn gene-cluster $cluster_count\n";
    $cluster_count++; 

    # pair_Transcripts returns (\@pairs,\@ann_unpaired,\@pred_unpaired,\@ann_doubled,\@pred_doubled)
    #print STDERR "pairing up transcripts ...\n";
    my ( $pairs, $ann_unpaired, $pred_unpaired ) = $gene_cluster->pair_Transcripts;
    print STDERR "found ".scalar(@$pairs)." pairs\n";
    
    # print the unpaired transcripts if gff_file is available
    if ($self->gff_file){
      foreach my $tran ( @$ann_unpaired ){
	$self->toGFF($tran,"annotation","unpaired");
      }
      foreach my $tran ( @$pred_unpaired ){
	$self->toGFF($tran,"prediction","unpaired");
      }
    }

    my @pairs = @{ $pairs };
    my @ann_unpaired;
    my @pred_unpaired;
    my @ann_doubled;
    my @pred_doubled;
    if ( $ann_unpaired ){
      push ( @ann_unpaired , @{ $ann_unpaired }  );
      $total_annotation_length  += $self->_get_length_of_Transcripts( $ann_unpaired );
    }
    if ( $pred_unpaired ){
      push ( @pred_unpaired, @{ $pred_unpaired } );
      $total_prediction_length  += $self->_get_length_of_Transcripts( $pred_unpaired );
    }
    
    #if ( $ann_doubled ){ 
    #  push ( @ann_doubled  , @{ $ann_doubled }   );    
    #}
    #if ( $pred_doubled ){
    #  push ( @pred_doubled , @{ $pred_doubled }  );
    #}
    #push ( @total_ann_doubled  , @ann_doubled   );
    #push ( @total_pred_doubled , @pred_doubled  );
    push ( @total_ann_unpaired , @ann_unpaired  ); 
    push ( @total_pred_unpaired, @pred_unpaired );

    # for each pair we keep track of the exon comparison
 
   PAIR:
    foreach my $pair ( @pairs ){
      $pairs_count++;
      
      # we match the exons in the pair
      my ($printout, $missing_stats, $over_stats, $mismatch_stats, $match_stats, $matchlength_stats) = 
	$self->_match_Exons($pair, $coding);

      # print to gff info about this pair if gff_file is available
      my ($prediction,$annotation) = $pair->get_Transcripts;
      if ($self->gff_file){
	#print STDERR "printing to GFF: ".$prediction->dbID.",".$annotation->dbID."\n";
		      
	$self->toGFF($prediction,"prediction",$global_count);
	$self->toGFF($annotation,"annotation",$global_count);
	$global_count++;
      }
      
      # where 
      # printout{ pair }{ exon_number }  = [ exon/no link, exon/no link, extra comments      ];
      # $missing_stats                   = [ $missing_exon_count , \%missing_exon_position   ];
      # $over_stats                      = [ $over_exon_count    , \%over_exon_position      ];
      # $mismatch_stats                  = [ $exon_mismatch_count                            ];
      # $match_stats                     = [ $exon_pair_count    , $thispair_exact_matches   ];
      # $matchlength_stats               = [ $prediction_matched, $annotation_length, $prediction_length ]; 

      my $missing_exon_count             = $$missing_stats[0];
      my %thispair_missing_exon_position = %{ $$missing_stats[1] };
      
      my $over_exon_count                = $$over_stats[0];
      my %thispair_over_exon_position    = %{ $$over_stats[1] };
      
      my $exon_mismatch_count            = $$mismatch_stats[0];
      
      my $thispair_exon_pair_count       = $$match_stats[0];
      my $thispair_exact_matches         = $$match_stats[1];

      # numerator in the computation of the sensitivity/specificity ( = TruePositive )
      $total_prediction_matched += $$matchlength_stats[0]; 

      # denominator in the computation of the sensitivity  ( = TruePositive + FalseNegative ) 
      $total_annotation_length  += $$matchlength_stats[1];
      
      # denominator in the computation of the specificity  ( = TruePositive + FalsePositive )
      $total_prediction_length  += $$matchlength_stats[2];

      #$exon_mismatch_count = $missing_exon_count + $over_exon_count;
      push ( @{ $missing{ $missing_exon_count } }    , $pair );
      push ( @{ $overpredicted{ $over_exon_count } } , $pair );
      push ( @{ $mismatches{ $exon_mismatch_count } }, $pair );

      $total_missing_exon_count += $missing_exon_count;
      $total_over_exon_count    += $over_exon_count;
      $total_exon_mismatches    += $exon_mismatch_count;
      $exact_matches            += $thispair_exact_matches;
      $exon_pair_count          += $thispair_exon_pair_count;

      foreach my $key ( keys( %thispair_missing_exon_position ) ){
	$missing_exon_position{ $key } += $thispair_missing_exon_position{ $key };
      }

      foreach my $key ( keys( %thispair_over_exon_position ) ){
	$over_exon_position{ $key } += $thispair_over_exon_position{ $key };
      }
      
      # print out info about this pair
      $self->_to_String( $pair, $printout );

    }        # end of  PAIR  loop      
  }          # end of  GENE  loop
 
  # get the other unpaired transcripts from the unclustered genes:
  foreach my $cluster ( $self->unclustered_Genes ){
    my @genes = $cluster->get_Genes;
    if ( scalar(@genes)>1 ){
      $self->throw("something went wrong, a cluster with 2 genes is classified as unclustered!");
    }
    my @transcripts = $genes[0]->each_Transcript;
    my $type = $genes[0]->type;
    my @annotation;
    my @prediction;
    push( @annotation, grep /$type/, @{ $self->{'_annotation_types'} } );
    push( @prediction, grep /$type/, @{ $self->{'_prediction_types'} } );
    if ( @annotation && !@prediction ){
      push ( @total_ann_unpaired, @transcripts );
    }
    elsif( !@annotation && @prediction ){
      push ( @total_pred_unpaired, @transcripts );
    }
    else{
      $self->warn("something is wrong, can't classify gene of type $type");
      next;
    }
  }

  # we recover info from this transcript pair comparison

  # print out the results
  print STDERR "Total number of transcript pairs: ".$pairs_count."\n";
  print STDERR "Transcripts unpaired: ".scalar( @total_ann_unpaired )." from annotation, and ". 
    scalar( @total_pred_unpaired )." from prediction\n";
  foreach my $tran ( @total_ann_unpaired ){
    my $id;
    if ( $tran->stable_id ){
      $id = $tran->stable_id;
    }
    elsif ( $tran->dbID ){
      $id = $tran->dbID;
    }
    print STDERR $id."\n";
  }
  foreach my $tran ( @total_pred_unpaired ){
    my $id;
    if ( $tran->stable_id ){
      $id = $tran->stable_id;
    }
    elsif ( $tran->dbID ){
      $id = $tran->dbID;
    }
    print STDERR $id."\n";
  }
  
  #print STDERR "Transcripts repeated: ".scalar( @total_ann_doubled )." from annotation, and ".
  #  scalar( @total_pred_doubled )." from prediction\n";
  #foreach my $tran ( @total_ann_doubled ){
  #  print STDERR $tran->stable_id."\n";
  #}
  #foreach my $tran ( @total_pred_doubled ){
  #  print STDERR $tran->stable_id."\n";
  #}

  print STDERR "\n";
  print STDERR "Exact matches                 : ".$exact_matches." out of ".$exon_pair_count."\n";  
  print STDERR "Total exon mismatches         : ".$total_exon_mismatches."\n";
  

  print STDERR "Exons missed by the prediction: ".$total_missing_exon_count."\n";
  if ( $missing_exon_position{"first"} ){
    printf STDERR " position %5s = %2d missed\n", ("first" , $missing_exon_position{"first"});
  }
  my @newkeys;
  foreach my $key ( keys ( %missing_exon_position ) ){
    unless ( $key eq "first" || $key eq "last" ){
      push ( @newkeys, $key );
    }
  }
  @newkeys = sort { $a <=> $b } @newkeys;
  foreach my $key ( @newkeys ) {
    if ( $key eq "first" || $key eq "last" ){
      next;
    }
    printf STDERR " position %5s = %2d missed\n", ($key , $missing_exon_position{$key});
  }
  if ( $missing_exon_position{"last"} ){
    printf STDERR " position %5s = %2d missed\n", ("last" , $missing_exon_position{"last"});
  }

  print STDERR "Exons overpredicted           : ".$total_over_exon_count."\n";
  foreach my $key ( keys( %over_exon_position ) ){
    printf STDERR " position %2s = %2d overpredicted\n", ($key , $over_exon_position{$key});
  }
  print STDERR "\n";

  # print out sensitivity/specificity of the prediction
  my $sensitivity = $total_prediction_matched/$total_annotation_length;
  my $specificity = $total_prediction_matched/$total_prediction_length;
  print STDERR "According to length of the prediction and benchmark:\n";
  print STDERR "sensitivity = $sensitivity\n";
  print STDERR "specificity = $specificity\n\n";
  
  if ($verbose){

    # print out the transcripts pairs with at least one exon missing
    print STDERR "Exons of genes ".$message1." which are missing in genes ".$message2.":\n";
    foreach my $key ( sort { $a <=> $b } ( keys( %missing ) ) ){
      my $these_pairs = scalar( @{ $missing{$key} } );
      my $percentage  = sprintf "%.2f", 100*$these_pairs/$pairs_count;
      print STDERR "\n$these_pairs transcript pairs with $key exon(s) missed: $percentage percent\n";
      foreach my $pair ( @{ $missing{ $key } } ){
	print STDERR $pair->to_String."\n";
      }
    }
  }

  if ($verbose){

    # print out the transcripts pairs with at least one exon overpredicted
    print STDERR "Exons of genes ".$message2." which are overpredicted with respect to genes ".$message1.":\n";
    foreach my $key ( sort { $a <=> $b } ( keys( %overpredicted ) ) ){
      my $these_pairs = scalar( @{ $overpredicted{$key} } );
      my $percentage  = sprintf "%.2f", 100*$these_pairs/$pairs_count;
      print STDERR "\n$these_pairs transcript pairs with $key exon(s) overpredicted: $percentage percent\n";
      foreach my $pair ( @{ $overpredicted{ $key } } ){
	print STDERR $pair->to_String."\n";
      }
    }
  }

  # print out the transcripts pairs with at least one exon mismatch
  print STDERR "Exons mismatches between genes ".$message1." and ".$message2.":\n";
  foreach my $key ( sort { $a <=> $b } ( keys( %mismatches ) ) ){
    my $these_pairs = scalar( @{ $mismatches{$key} } );
    my $percentage  = sprintf "%.2f", 100*$these_pairs/$pairs_count;
    print STDERR "\n$these_pairs transcript pairs with $key exon(s) mismatch: $percentage percent\n";
    
    if ($verbose){
      foreach my $pair ( @{ $mismatches{ $key } } ){
	print STDERR $pair->to_String."\n";
      }
    }
  
  }
  # we return the hash with the arrays of transcript pairs as values, and 
  # the number of missing exons as keys, that can be used to make a histogram
  return %missing;
}

####################################################################################


=head2 _match_Exons()
  
  Title   : _match_Exons
  Function: this is the actual method that tries to match exons and store the info
            in hashes and then return them. This is done per Transcript Pair
  Args    : a pair of transcripts in the form of a TranscriptCluster object

=cut

sub _match_Exons{
  my ($self, $pair, $coding ) = @_;
  
  my $prediction_matched  = 0; #  ( = TruePositive )
  my $annotation_length   = 0; #  ( = TruePositive + FalseNegative )
  my $prediction_length   = 0; #  ( = TruePositive + FalsePositive )

  my $missing_exon_count  = 0;
  my $over_exon_count     = 0; # counts the number of overpredicted exons
  my $exon_mismatch_count = 0;
  my $exon_pair_count     = 0;
  my $exact_matches       = 0;
  
  my %missing_exon_position;
  my %over_exon_position;

  # the order is given by the order they are put into the pair in GeneCluster
  my ($prediction,$annotation) = $pair->get_Transcripts;
  
  # get the exons
  my (@ann_exons,@pred_exons);
  if ($coding){
    
    # get only the CDS from the exons... if there is a translation
    if ( $annotation->translation ){
      @ann_exons = $annotation->translateable_exons;
    }
    else{
      print STDERR "transcript ".$annotation->stable_id." has no translation, skipping this pair:\n";
      print STDERR $pair->to_String."\n";
      next PAIR;
    }
    if ( $prediction->translation ){
      @pred_exons= $prediction->translateable_exons;
    }
    else{
      print STDERR "transcript ".$prediction->stable_id." has no translation, skipping this pair:\n";
      print STDERR $pair->to_String."\n";
      next PAIR;
    }
  }
  else{
    @ann_exons  = $annotation->get_all_Exons;
    @pred_exons = $prediction->get_all_Exons;
  }
  
  # compute TruePositive + FalseNegative
  foreach my $exon (@ann_exons){
    $annotation_length       += $exon->length;
  }
  
  # compute TruePositive + FalsePositive
  foreach my $exon (@pred_exons){
    $prediction_length       += $exon->length;
  }
  
  # order exons according to the strand
  if ( $ann_exons[0]->strand == 1 ){
    @ann_exons  = sort{ $a->start <=> $b->start } @ann_exons;
    @pred_exons = sort{ $a->start <=> $b->start } @pred_exons;
  }
  if ( $ann_exons[0]->strand == -1 ){
    @ann_exons  = sort{ $b->start <=> $a->start } @ann_exons;
    @pred_exons = sort{ $b->start <=> $a->start } @pred_exons;
  }
  
  # now we link the exons, but first, a bit of formatted info
  #print  "\nComparing transcripts:\n";
  #print STDERR $pair->to_String;
  
  my %link;
  my $start=0;    # start looking at the first one
  my @buffer;     # buffer that keeps track of the skipped exons in @exons2 

  my $sensitivity;
  my $specificity;
  my $printout;
  my $printout_count = 1;
  
  $$printout{ $pair }{ 0 } = [ "annotation", "prediction", "" ];

  # Note: variables start at ZERO, but in the print-outs we shift them to start at ONE
 EXONS1:
  for (my $i=0; $i<=$#ann_exons; $i++){
    my $foundlink = 0;
    
  EXONS2:
    for (my $j=$start; $j<=$#pred_exons; $j++){
      
      # compare $ann_exons[$i] with $pred_exons[$j] 
      if ( $ann_exons[$i]->overlaps($pred_exons[$j]) ){
	
	# if you've found a link, check first whether there is anything left unmatched in @buffer
	if ( @buffer && scalar(@buffer) != 0 ){
	  foreach my $exon_number ( @buffer ){
	    $$printout{ $pair }{ $printout_count } = ["no link",$exon_number,""];
	    $printout_count++;
	    $over_exon_count++;
	    
	    if ( $exon_number == 1 ){
	      $over_exon_position{'first'}++;
	    }
	    elsif ( $exon_number == $#pred_exons+1 ){
	      $over_exon_position{'last'}++;
	    }
	    else {
	      $over_exon_position{ $exon_number }++;
	    }	     
	  }
	}
	$foundlink = 1;
	$exon_pair_count++;

	# then check whether it is exact
	if ( $ann_exons[$i]->equals( $pred_exons[$j] ) ){
	  $$printout{ $pair }{ $printout_count } = [ ($i+1) , ($j+1) , "exact" ];
	  $printout_count++;
	  
	  $prediction_matched += $pred_exons[$j]->length;
	  $exact_matches++;
	}
	
	# or there is a mismatch in the number of bases
	else{              
	  my $overlap = $self->_exon_Overlap($ann_exons[$i],$pred_exons[$j]);
	  $prediction_matched += $overlap;

	  my $message = '';
	  if ( $ann_exons[$i]->start != $pred_exons[$j]->start ){
	    my $mismatch = ($ann_exons[$i]->start - $pred_exons[$j]->start);
	    my $absolute_mismatch = abs( $mismatch );
	    my $msg;
	    if ( $mismatch > 0 ){
	      $msg = "prediction has $absolute_mismatch extra bases in the";
	    }
	    elsif( $mismatch < 0 ){
	      $msg = "prediction misses $absolute_mismatch bases in the";
	    }
	    if ( $ann_exons[$i]->strand == 1 ){
	      $msg .= " 5' end, ";
	    }
	    elsif ( $ann_exons[$i]->strand == -1 ){
	      $msg .= " 3' end, ";
	    }
	    $message .= $msg;
	  }
	  if (  $ann_exons[$i]->end  != $pred_exons[$j]->end   ){
	    my $mismatch = ($ann_exons[$i]->end  -  $pred_exons[$j]->end  );
	    my $absolute_mismatch = abs( $mismatch );
	    my $msg;
	    if ( $mismatch > 0 ){
	      $msg = "prediction misses $absolute_mismatch bases in the";
	    }
	    elsif( $mismatch < 0 ){
	      $msg = "prediction has $absolute_mismatch extra bases in the";
	    }
	    if ( $ann_exons[$i]->strand == 1 ){
	      $msg .= " 3' end, ";
	    }
	    elsif ( $ann_exons[$i]->strand == -1 ){
	      $msg .= " 5' end, ";
	    }	      
	    $message .= $msg;
	  }
	  $$printout{ $pair }{ $printout_count } = [ ($i+1) , ($j+1) , $message ];
	  $printout_count++;
	}
	$start += scalar(@buffer)+1;
	
	# we start a new buffer
	@buffer = ();  
	next EXONS1;
      }
      # if no overlap, skip this one
      else {  
	# keep this info in a @buffer if you haven't exhausted all checks in @exons2  
	if ( $j<$#pred_exons ){
	  push ( @buffer, ($j+1) );
	}
	# if you got to the end of @exons2 and found no link, ditch the @buffer
	elsif ( $j == $#pred_exons ){ 
	  @buffer = ();
	}
	# and get outta here              
	next EXONS2;
      }
    }   # end of EXONS2 loop
    
    # found no link for $ann_exons[$i], go to the next one
    if ( $foundlink == 0 ){  
      $$printout{ $pair }{ $printout_count } = [ ($i+1) , "no link"  , "" ];
      $printout_count++;
      $missing_exon_count++;
      if ( $i+1 == 1 ){
	$missing_exon_position{'first'}++; 
      }
      elsif ( $i+1 == $#ann_exons+1 ){  
	$missing_exon_position{'last'}++; 
      }
      else {  
	$missing_exon_position{ $i+1 }++; 
      }	  
      # see whether there is any feature we could have used 
      # WARNING: this method works but it is extremely slow
      #my ($similarity_features, $prediction_features) = $self->_missed_exon_Evidence( $pair, $ann_exons[$i] );
    }
  }       # end of EXONS1 loop

  # stats
  $exon_mismatch_count  = $over_exon_count + $missing_exon_count;

  my $missing_stats     = [ $missing_exon_count , \%missing_exon_position ];
  my $over_stats        = [ $over_exon_count    , \%over_exon_position    ];
  my $mismatch_stats    = [ $exon_mismatch_count                          ];
  my $match_stats       = [ $exon_pair_count    , $exact_matches          ];
  my $matchlength_stats = [ $prediction_matched, $annotation_length, $prediction_length ];

  # we return printout{ pair }{ exon_number } = [ exon/no link, exon/no link, extra comments ]
  return ( $printout, $missing_stats, $over_stats, $mismatch_stats, $match_stats , $matchlength_stats);
}

####################################################################################

sub _exon_Overlap{
  my ($self, $exon1,$exon2) = @_;
  my $strand1 = $exon1->strand;
  my $strand2 = $exon2->strand;
  if ( $strand1 =! $strand2 ){
    print STDERR "Odd - comparig exons in different strands\n";
    return 0;
  }
  my $s1 = $exon1->start;
  my $s2 = $exon2->start;
  my $e1 = $exon1->end;
  my $e2 = $exon2->end;

  my $overlap = 0;
  if ( $s1 <= $s2 && $e1 >= $s2 ){
    if ( $e1 <= $e2 ){
      $overlap = $e1 - $s2 + 1;
    }
    if ( $e1 > $e2 ){
      $overlap = $e2 - $s2 + 1;
    }
  }
  if ( $s1 >= $s2 && $s1 <= $e2 ){
    if ( $e1 <= $e2 ){
      $overlap = $e1 - $s1 + 1;
    }
    if ( $e1 > $e2 ){
      $overlap = $e2 - $s1 + 1;
    }
  }
  
  return $overlap;
}


####################################################################################

sub _get_length_of_Transcripts {
  my ($self,$arrayref) = @_;
  my @transcripts = @$arrayref;
  if ( @transcripts ){
   unless ( $transcripts[0]->isa('Bio::EnsEMBL::Transcript') ){
     $self->warn("you must pass an arrayref of Bio::EnsEMBL::Transcript objects");
   }
   my $total_exon_length;
   foreach my $transcript ( @transcripts){
     foreach my $exon ( $transcript->get_all_Exons ){
       $total_exon_length += $exon->length;
     }
   }
   return $total_exon_length;
  }
  else{
   return 0;
  }
}

####################################################################################


sub input_id {  
  my ($self,$input_id) = @_;

  if ($input_id){
    $self->{'_input_id'} = $input_id;
    my $chr      = $input_id;
    $chr         =~ s/\.(.*)-(.*)//;
    my $chrstart = $1;
    my $chrend   = $2;
    if ( $chr && $chrstart && $chrend ){
      $self->chr_name(  $chr);
      $self->chr_start( $chrstart );
      $self->chr_end(   $chrend  );
    }
  }
  return $self->{'_input_id'};
}


sub chr_name{
  my ($self,$chr_name) = @_;
  if ($chr_name){
    $self->{'_chr_name'} = $chr_name;
  }
  return $self->{'_chr_name'};
}


sub chr_start{
  my ($self,$chr_start) = @_;
  if ($chr_start){
    $self->{'_chr_start'} = $chr_start;
  }
  return $self->{'_chr_start'};
}


sub chr_end{
  my ($self,$chr_end) = @_;
  if ($chr_end){
    $self->{'_chr_end'} = $chr_end;
  }
  return $self->{'_chr_end'};
}




####################################################################################


#=head2 _missed_exon_Evidence

#Function: It searches for possible evidence that we could have used to predict the missed exon passed as argument

#=cut

#sub _missed_exon_Evidence{
#  my ($self, $pair, $exon) = @_;

#  # take the missed exon (virtual contig) coordinates
#  my ( $start, $end ) = ( $exon->start, $exon->end );

#  # we need to get info from the annotation database
#  my $dbname    = $DBNAME1;
#  my $dbuser    = $DBUSER1;
#  my $path      = $PATH1;
#  my $host      = $DBHOST1;
#  my $genetypes = $GENETYPES1; # this is an arrayref 
  
#  my $db = new Bio::EnsEMBL::DBSQL::DBAdaptor(
#					      -host             => $host,
#					      -user             => $dbuser,
#					      -dbname           => $dbname,
#					     );

#  $db->static_golden_path_type($path);
#  my $sgp = $db->get_StaticGoldenPathAdaptor;
  
#  # get info of where we are sitting:
#  my ($chr,$chrstart,$chrend) = $self->input_id;
#  unless ( $chr && $chrstart && $chrend ){
#    $self->throw( "You must provide a chr_name, chr_start and a chr_end" );
#  }
  
#  # get a virtual contig for that piece we're interested in
#  my ($start_pos,$end_pos) = ( $chrstart + $start, $chrstart + $end);
#  my $vcontig = $sgp->fetch_VirtualContig_by_chr_start_end($chr,$start_pos,$end_pos);
  
#  # get features from that piece
#  my @similarity_features = $vcontig->get_all_SimilarityFeatures;
#  my @prediction_features = $vcontig->get_all_PredictionFeatures;

#  print STDERR scalar(@similarity_features)." similarity features retrieved in this range\n";
#  print STDERR scalar(@prediction_features)." prediction features retrieved in this range\n";

#  return ( \@similarity_features, \@prediction_features );
  
#}

#####################################################################################  

=head2 exon_Density()

=cut

sub exon_Density{
  my ($self, @transcripts) = @_;  
  my $sum_density;
  foreach my $tran (@transcripts){
    my $exon_span;
    my @exons = $tran->get_all_Exons;
    @exons = sort { $a->start <=> $b->start } @exons;
    my $transcript_length = $exons[$#exons]->end - $exons[0]->start;
    foreach my $exon ( $tran->get_all_Exons ){
      $exon_span += $exon->length;
    }
    $sum_density += $exon_span/$transcript_length;
  }
  return $sum_density;
}

####################################################################################


=head2 _to_String();

=cut

sub _to_String{
  my ($self, $pair, $printout ) = @_;
  my $count = 0;
  while ( $$printout{ $pair }{ $count } ){
    my $msg;
    my ( $str1, $str2, $str3 ) = ( '', '', '' );
    
    # exons in annotation (or 'no link' )
    $str1 = ${ $$printout{$pair}{$count} }[0];

    # exons in prediction (or 'no link' )
    $str2 = ${ $$printout{$pair}{$count} }[1];

    # comments: exact, mismatch bases
    $str3 = ${ $$printout{$pair}{$count} }[2];
    
    if ( $count == 0 ){
      $msg = sprintf "%10s   %-2s  %s\n", ( $str1, $str2, $str3 );
    }
    else{
      $msg = sprintf "%8s <----> %-2s  %s\n", ( $str1, $str2, $str3 );
    }
    print STDERR $msg;
    $count++;
  }
}
  
####################################################################################

=head2 get_Exon_Statistics()

  This method produces an histogram with the number of exon pairs per percentage overlap.
  The percentage overlap of two exons, say e1 and e2, is calculated in _compare_Transcripts method as
  100*intersection(e1,e2)/max_length(e1,e2). It takes whole exons, i.e. without chopping out the 
  non-coding part. This method returns a hash containing the number of occurences as values and
  the integer percentage overlap as keys

=cut
  
sub get_Exon_Statistics{

  my ($self,$array1,$array2) = @_;
  my (@transcripts1,@transcripts2);
  my %stats;
  if ($array1 && $array2){         # we can pass two arrays references (to transcripts) as argument
    @transcripts1 = @{$array1};
    @transcripts2 = @{$array2};
    
  }
  else{                            # or else read the transcripts from the data fields
    my @genes1 = $self->annotation_Genes;
    foreach my $gene (@genes1){
      my @more_transcripts = $gene->each_Transcript;
      push ( @transcripts1, @more_transcripts );
    }
    my @genes2 = $self->prediction_Genes;
    foreach my $gene (@genes2){
      my @more_transcripts = $gene->each_Transcript;
      push ( @transcripts2, @more_transcripts );
    }
  }
  foreach my $t1 (@transcripts1){
    foreach my $t2 (@transcripts2){
      if ( _compare_Transcripts($t1,$t2) ){
	my %partial_stats = _exon_Statistics($t1,$t2); # produces the stats for the current two transcripts
	                                               # The hash holds number of occurences as values and
	                                               # integer percentage overlap as keys
	foreach my $k ( keys %partial_stats ) {
	  $stats{$k} += $partial_stats{$k};            # Here it adds up to the overall value
	}
      }
    }
  }
  return %stats;
}

#########################################################################

=head2 _exon_Statistics()

This internal function reads two transcripts and calculates the percentage of overlap 
between their exons = (INTERSECT($exon1,$exon2))/MAX($exon1,$exon2)

=cut

sub _exon_Statistics {
  my ($transcript1,$transcript2) = @_;
  my @exons1 = $transcript1->get_all_Exons; # transcripts get their exons in order
  my @exons2 = $transcript2->get_all_Exons;

  my %stats;

  foreach my $exon1 (@exons1){
  
    foreach my $exon2 (@exons2){

      if ( ($exon1->overlaps($exon2)) && ($exon1->strand == $exon2->strand) ){
	
	# calculate the percentage of exon overlap = (INTERSECT($exon1,$exon2))/MAX($exon1,$exon2)
	my $max;
	if ( ($exon1->length) < ($exon2->length) ){
	  $max = $exon2->length;
	}
	else{
	  $max = $exon1->length;
	}
	# compute the overlap extent
	
	my ($s,$e);  # start and end coord of the overlap
	my ($s1,$e1) = ($exon1->start,$exon1->end);
	my ($s2,$e2)= ($exon2->start,$exon2->end);
	if ($s1<=$s2 && $s2<$e1){
	  $s=$s2;
	}
	if ($s1>=$s2 && $e2>$s1){
	  $s=$s1;
	}
	if ($e1<=$e2 && $e1>$s2){
	  $e=$e1;
	}
	if ($e2<=$e1 && $e2>$s1){
	  $e=$e2;
	}
	my $common = ($e - $s + 1);
	my $percent = int( (100*$common)/$max );
	$stats{$percent}++;	
      }
    }
  }
  return %stats;
}    

####################################################################################

=head2 get_Coding_Exon_Statistics()

  The same aim as the get_Exon_Statistics method but chopping the non-coding part from the exons.
  This method returns a hash containing the number of occurences as values and
  the integer percentage overlap as keys

=cut
  
sub get_Coding_Exon_Statistics{

  my ($self,$array1,$array2) = @_;
  my (@transcripts1,@transcripts2);
  my %stats;
  if ($array1 && $array2){       # we can pass two arrays references of transcripts as argument
    @transcripts1 = @{$array1};
    @transcripts2 = @{$array2};
    
  }
  else{                          # or else read the transcripts from the gene_array data fields
    my @genes1 = $self->annotation_Genes;
    foreach my $gene (@genes1){
      my @more_transcripts = $gene->each_Transcript;
      push ( @transcripts1, @more_transcripts );
    }
    my @genes2 = $self->prediction_Genes;
    foreach my $gene (@genes2){
      my @more_transcripts = $gene->each_Transcript;
      push ( @transcripts2, @more_transcripts );
    }
  }
  # in order to get info about the non-coding regions of the transcripts we have
  # to get translation objects for them, however, some of them do not have it defined.
  # In those cases we just ignore the comparison.
  
  foreach my $t1 (@transcripts1){
    foreach my $t2 (@transcripts2){
	if ($t1->translation && $t2->translation){
	  my %partial_stats = _coding_Exon_Statistics($t1,$t2);
	  foreach my $k ( keys %partial_stats ) {
	    $stats{$k} += $partial_stats{$k};
	  }
	}
	else{
	  print "Transcript without translation:\n";
	  if (!$t1->translation){
	    print $t1->stable_id."\n";
	  }
	  if (!$t2->translation){
	    print $t2->stable_id."\n";
	  }
	  print "\n";
	}
    }
  }
  return %stats;
}

####################################################################################  

=head2 _coding_Exon_Statistics()

This internal function reads two transcripts and calculates the percentage 
of overlap between the coding exons = (INTERSECT($exon1,$exon2))/MAX($exon1,$exon2)

=cut

sub _coding_Exon_Statistics {         

  # the coding region may start in any exon, not necessarily the first one
  # and may end in any one as well
  my ($transcript1,$transcript2) = @_;

  my @exons1 = $transcript1->get_all_Exons;
  my @exons2 = $transcript2->get_all_Exons;

  my $translation1 = $transcript1->translation;
  my $translation2 = $transcript2->translation;


  # IDs of the exons where the coding region starts and ends
  my ($s_id1,$e_id1) = ($translation1->start_exon_id,$translation1->end_exon_id);
  my ($s_id2,$e_id2) = ($translation2->start_exon_id,$translation2->end_exon_id);


  # identify those exons in each transcript
  my ($s_exon1,$e_exon1);  # these will be the exons where the coding region (starts,ends) in the 1st transcript

  foreach my $exon1 (@exons1){
    if ($exon1->dbID eq $s_id1){
      $s_exon1 = $exon1;
    }
    if ($exon1->dbID eq $e_id1){
      $e_exon1 = $exon1;
    }
  }
  my ($s_exon2,$e_exon2);  # these will be the exons where the coding region (starts,ends) in the 2nd transcript
  foreach my $exon2 (@exons2){
    if ($exon2->dbID eq $s_id2){
      $s_exon2 = $exon2;
    }
    if ($exon2->dbID eq $e_id2){
      $e_exon2 = $exon2;
    }
  }
print "Exon of 2ndt transcript\n";
foreach my $e2 (@exons2){
print "Exon ".$e2->strand." ".$e2->start." ".$e2->end."\n";
}


  # take these exons and those in between these exons (since only these exons contain coding region)
  my @coding_exons1;

  foreach my $exon1 (@exons1){
	if ($exon1->strand eq 1){
    	if ( $exon1->start >= $s_exon1->start && $exon1->start <= $e_exon1->end ){
      		push ( @coding_exons1, $exon1 );
		}
	}else{
    	if ( $exon1->start >= $e_exon1->end && $exon1->start <= $s_exon1->start ){
     		push ( @coding_exons1, $exon1 );
		}
	}
  }
print "coding region start: ".$s_exon2->start." end: ".$e_exon2->end."\n";



  my @coding_exons2;


	foreach my $exon2 (@exons2){
	if ($exon2->strand eq 1){
        	if ( $exon2->start >= $s_exon2->start && $exon2->start <= $e_exon2->end ){
            	push ( @coding_exons2, $exon2 );
        	}
		}else{
    		if ( $exon2->start >= $e_exon2->end && $exon2->start <= $s_exon2->start ){
      		push ( @coding_exons2, $exon2 );
			}
		}
  	}

  @exons1 = @coding_exons1;
  @exons2 = @coding_exons2;
    
  # start and end of coding regions 
  # relative to the origin of the first and last exons where the coding region starts
  my ($s_code1,$e_code1) = ($translation1->start,$translation1->end);
  my ($s_code2,$e_code2) = ($translation2->start,$translation2->end);
 
  # here I hold my stats results
  my %stats;
  
  foreach my $exon1 (@exons1){

    foreach my $exon2 (@exons2){

      if ( ($exon1->overlaps($exon2)) && ($exon1->strand == $exon2->strand) ){
	# start and end coord of the overlap
	my ($s,$e)=(0,0);  

	# exon positions
	my ($s1,$e1) = ($exon1->start,$exon1->end);
	my ($s2,$e2)= ($exon2->start,$exon2->end);
	
	#exon lengths
	my ($l1,$l2) = ($exon1->length, $exon2->length);

	# One has to chop off the non-coding part out of the first and last exons in 
	# the coding region : ($s_id1,$e_id1) and ($s_id2,$e_id2)
	# Recall that ($s_code1,$e_code1) and ($s_code2,$e_code2) are the start/end of the coding regionS
	
	my ($fs1,$fe1,$fs2,$fe2)=(0,0,0,0); # put a flag on the first and last exons to print them out

	if ($exon1->dbID eq $s_id1){
	  $s1 = $s1 + $s_code1 - 1;
	  $l1 = $e1 - $s1 + 1;
	  $fs1=1;
	}
	if ($exon1->dbID eq $e_id1){
	  $e1 = $s1 + $e_code1 - 1;
	  $l1 = $e1 - $s1 + 1;
	  $fe1=1;
	}
	if ($exon2->dbID eq $s_id2){
	  $s2 = $s2 + $s_code2 - 1;
	  $l2 = $e2 - $s2 + 1;
	  $fs2=1;
	}
	if ($exon2->dbID eq $e_id2){
	  $e2 = $s2 + $e_code2 - 1;
	  $l2 = $e2 - $s2 + 1;
	  $fe2=1;
	}

	# calculate the percentage of exon overlap = (INTERSECT($exon1,$exon2))/MAX($exon1,$exon2)
	my $max;
	if ( $l1 < $l2 ){
	  $max = $l2;
	}
	else{
	  $max = $l1;
	}
	
	# compute the overlap extent
	if ($s1<=$s2 && $s2<$e1){
	  $s=$s2;
	}
	if ($s1>=$s2 && $e2>$s1){
	  $s=$s1;
	}
	if ($e1<=$e2 && $e1>$s2){
	  $e=$e1;
	}
	if ($e2<=$e1 && $e2>$s1){
	  $e=$e2;
	}
	my $common = ($e - $s + 1);
	if ($common != 0){ # we check since after cutting the non-coding piece we might lose the overlap
	  my $percent = int( (100*$common)/$max );
	  $stats{$percent}++;	
	  if ($fs1 || $fs2 ) { 
	    print "(".$s1.",".$e1.")";
	    if ($fs1){
	      print "-> start coding exon";
	    }
	    print "\t".$exon1->stable_id."\n";
	    
	    print "(".$s2.",".$e2.")";
	    if ($fs2) { 
	      print "-> start coding exon";
	    }
	    print "\t".$exon2->stable_id."\n";
	  }
	  if ( $fe1 || $fe2 ) { 
	    print "(".$s1.",".$e1.")";
	    if ($fe1){
	      print "-> end coding exon";
	    }
	    print   "\t".$exon1->stable_id."\n";
	    
	    print "(".$s2.",".$e2.")";
	    if ($fe2) { print "-> end coding exon";
		      }  
	    print "\t".$exon2->stable_id."\n";
	  }
	  if ($fs1 || $fs2 || $fe1 || $fe2){ print "(".$s.",".$e.") Overlap --> ".$percent."\n\n";}
	}
      }
    }
  }
  return %stats;
}    


####################################################################################  
  
=head2 get_unmatched_Genes()

  This function returns those genes that have not been identified with any other gene in the
  two arrays (of type1 and type2) passed to GeneComparison->new(). If we have clustered the genes
  before, then we have probably filled the array $self->{'_unclustered_genes'}, so we can read out the 
  unmatched genes from there. If not, it derives the unmatched genes
  directly from the gene_arrays passed to the GeneComaprison object. 

  It returns two references to two arrays of GeneCluster objects. 
  The first one corresponds to the genes of type1 which have not been identified in type2, 
  and the second one holds the genes of type2 that have not been 
  identified with any of the genes of type1. 
  
=cut

sub get_unmatched_Genes {
  my $self = shift @_;
  
  # if we have already the unclustered genes, we can read them out from $self->{'_unclustered_genes'}
  if ($self->unclustered ){
    my @types1 = @{ $self->{'_annotation_types'} };
    my @types2 = @{ $self->{'_prediction_types'} };
    my @unclustered = $self->unclustered; 
    my (@array1,@array2);
    foreach my $cluster (@unclustered){
      my $gene = ${ $cluster->get_Genes }[0]; 
      foreach my $type1 ( @{ $self->{'_annotation_types'} } ){
	if ($gene->type eq $type1){
	  push ( @array1, $gene );
	}
      }
      foreach my $type2 ( @{ $self->{'_prediction_types'} } ){
	if ($gene->type eq $type2){
	  push ( @array2, $gene );
	}
      }
    }
    return (\@array1,\@array2);
  }

  # if not, we can compute them directly
  my (%found1,%found2);

  foreach my $gene1 ( $self->annotation_Genes ){
    foreach my $gene2 ( $self->prediction_Genes ){
      if ( _compare_Genes($gene1,$gene2)){
	$found1{$gene1->stable_id} = 1;
	$found2{$gene2->stable_id} = 1;
      }
    }
  }
  my @unmatched1;
  foreach my $gene1 ( $self->annotation_Genes ){
    unless ( $found1{$gene1->stable_id} ){
      my $new_cluster = Bio::EnsEMBL::Pipeline::GeneComparison::GeneCluster->new();
      $new_cluster->gene_Types($self->gene_Types);
      $new_cluster->put_Genes($gene1);
      push (@unmatched1, $new_cluster);
    }
  }
  my @unmatched2;
  foreach my $gene2 ( $self->prediction_Genes ){
    unless ( $found2{$gene2->stable_id} ){
      my $new_cluster = Bio::EnsEMBL::Pipeline::GeneComparison::GeneCluster->new();
      $new_cluster->gene_Types($self->gene_Types);
      $new_cluster->put_Genes($gene2);
      push (@unmatched2, $new_cluster);
    }
  }
  return (\@unmatched1,\@unmatched2);
}

#########################################################################

=head2 get_fragmented_Genes()

it returns an array of GeneCluster objects, where these objects contain
fragmented genes: genes of a given type which are overlapped with more than one
gene of the other type. In order to avoid repetition of work, if a gene-clustering
has been already performed, one can pass the array of clusters as an argument.
This, however, is only allowed if _annotation_types and _prediction_types are defined, since the method
makes use of them.

=cut

sub get_fragmented_Genes {
  my ($self,@array) = @_;
  my @clusters;
  my @fragmented;

  if (@array && $self->{'_annotation_types'} && $self->{'_prediction_types'} ){
    @clusters = @array;
  }
  else{
    @clusters = $self->cluster_Genes;
  }
  
  foreach my $cluster (@clusters){
    
    my @genes = $cluster->get_Genes;
    my (@type1,@type2);
    
    foreach my $gene ( @genes ){
     
      my $type = $gene->type;
      push( @type1, grep /$type/, @{ $self->{'_annotation_types'} } );
      push( @type2, grep /$type/, @{ $self->{'_prediction_types'} } );
      # @type1 and @type2 hold all the occurrences of gene-types 1 and 2, respectively
      if ( ( @type1 && scalar(@type1)>1 ) || ( @type2 && scalar(@type2) >1 ) ) {
	push (@fragmented, $cluster);
      }
    }
  }
  return @fragmented;
}

#########################################################################


=head2 get_3prime_overlaps()

=cut

#########################################################################

=head2 get_5prime_overlaps()

=cut

#########################################################################


=head2 _compare_Genes()

 Title: _compare_Genes
 Usage: this internal function compares the exons of two genes on overlap

=cut

sub _compare_Genes {         
  my ($gene1,$gene2) = @_;
  my @exons1 = $gene1->get_all_Exons;
  my @exons2 = $gene2->get_all_Exons;
  
  foreach my $exon1 (@exons1){
  
    foreach my $exon2 (@exons2){

      if ( ($exon1->overlaps($exon2)) && ($exon1->strand == $exon2->strand) ){
	return 1;
      }
    }
  }
  return 0;
}      
#########################################################################



=head2 _compare_Transcripts()

 Title: _compare_Transcripts()
 Usage: this internal function compares the exons of two transcripts according to overlap
        and returns the number of overlaps
=cut

sub _compare_Transcripts {         
  my ($transcript1,$transcript2) = @_;
  my @exons1   = $transcript1->get_all_Exons;
  my @exons2   = $transcript2->get_all_Exons;
  my $overlaps = 0;
  
  foreach my $exon1 (@exons1){
    
    foreach my $exon2 (@exons2){

      if ( ($exon1->overlaps($exon2)) && ($exon1->strand == $exon2->strand) ){
	$overlaps++;
      }
    }
  }
  return $overlaps;  # we keep track of the number of overlaps to be able to choose the best match
}    

#########################################################################

=head2 unclustered_Genes()

 Title  : unclustered_Genes()
 Usage  : This function stores and returns an array of GeneClusters with only one gene (unclustered) 
 Args   : a Bio::EnsEMBL::Pipeline::GeneComparison::GeneCluster object
 Returns: an array of Bio::EnsEMBL::Pipeline::GeneComparison::GeneCluster objects

=cut

sub unclustered_Genes{
    my ($self, @unclustered) = @_;
 
    if (@unclustered)
    {
       $self->throw("Input @unclustered is not a Bio::EnsEMBL::Pipeline::GeneComparison::GeneCluster\n")
       unless $unclustered[0]->isa('Bio::EnsEMBL::Pipeline::GeneComparison::GeneCluster');

        push ( @{ $self->{'_unclustered_genes'} }, @unclustered);
    }
    return @{ $self->{'_unclustered_genes'} };
}

#########################################################################

=head2 gene_Clusters()

	Title: gene_Clusters()
	Usage: This function stores and returns an array of clusters

=cut
sub gene_Clusters {
    my ($self, @clusters) = @_;
 
    if (@clusters)
    {
        push (@{$self->{'_gene_clusters'}}, @clusters);
    }
    return @{$self->{'_gene_clusters'}};
}

#########################################################################

=head2 transcript_Clusters()

	Title: transcript_Clusters()
	Usage: This function stores and returns an array of transcript_Clusters

=cut
sub transcript_Clusters {
    my ($self, @clusters) = @_;
 
    if (@clusters)
    {
        push (@{$self->{'_transcript_clusters'}}, @clusters);
    }
    return @{$self->{'_transcript_clusters'}};
}
#########################################################################

=head2 flush_transcript_Clusters()

	Usage: This function cleans up the array in $self->{'_transcript_clusters'}

=cut

sub flush_transcript_Clusters {
    my ($self) = @_;
    $self->{'_transcript_clusters'} = [];
}


#########################################################################

=head2 flush_gene_Clusters()

	Usage: This function cleans up the array in $self->{'_gene_clusters'}

=cut

sub flush_gene_Clusters {
    my ($self) = @_;
    $self->{'_gene_clusters'} = [];
}

#####################################################################################

=head2
  
  This method compares the genomic lengths spanned by the prediction and the benchmark exons.
  It takes all the ranges of genomic sequece as a 1-dimensional projection of the exons from both sides and
  calculates the overlap relative to each total length.

=cut

sub exon_Coverage{
  my ($self,$ann_genes,$pred_genes,$lower_bound) = @_;
  
  # first get all exons
  my @ann_exons;
  my @pred_exons;
  foreach my $tran ( @$ann_genes ){
    push ( @ann_exons, $tran->get_all_Exons );
  }
  foreach my $tran ( @$pred_genes ){
    push ( @pred_exons, $tran->get_all_Exons );
  }

  # now cluster the exons for each side
  my $ann_cluster_list  = $self->_cluster_Exons( @ann_exons  );
  my $pred_cluster_list = $self->_cluster_Exons( @pred_exons );

  # get the list of ranges in each side:
  my @ann_ranges  = $ann_cluster_list->sub_SeqFeature;
  my @pred_ranges = $pred_cluster_list->sub_SeqFeature;

  # calculate the length of genome covered by each set of exons:
  my $ann_length  = 0;
  my $pred_length = 0;
  foreach my $range ( @ann_ranges ){
    $ann_length += $range->end - $range->start + 1;
  }
  foreach my $range ( @pred_ranges ){
    $pred_length += $range->end - $range->start + 1;
  }
  
  # now calculate the length of overlap between exons
  my $overlap_length = 0;
  foreach my $ann_range ( @ann_ranges ){
    foreach my $pred_range ( @pred_ranges ){
      unless ( $pred_range->start > $ann_range->end || $pred_range->end < $ann_range->start ){
	$overlap_length += $self->_exon_Overlap($ann_range, $pred_range);
      }
    }
  }

  print STDERR "EXON COVERAGE ACCORDING TO EXON-GENOMIC LENGTH\n";
  print STDERR "Total length of prediction: $pred_length\n";
  print STDERR "                annotation: $ann_length\n";
  print STDERR "                   overlap: $overlap_length\n\n";
  
  my $sensitivity = $overlap_length/$ann_length;
  my $specificity = $overlap_length/$pred_length;

  print STDERR "               Sensitivity: $sensitivity\n";
  print STDERR "               Specificity: $specificity\n";
  print STDERR "\n";


  ### now calculate the coverage according to $lower_bound percentage overlap
  if (defined($lower_bound)){
    my %seen_exon3;
    my $count_covered_exons3 = 0;
    my %perc_overlap_distribution3;
    
  ANN_EXON:
    foreach my $ann_exon ( @ann_exons ){
      if ( $seen_exon3{ $ann_exon } ){
	next ANN_EXON;
      }
      
  PRED_EXON:
    foreach my $pred_exon ( @pred_exons ){
      if ( $seen_exon3{ $pred_exon } ){
	next PRED_EXON;
      }
      if ( $ann_exon->overlaps( $pred_exon ) ){
	my $overlap_length = $self->_exon_Overlap($ann_exon, $pred_exon);
	my $ann_length     = $ann_exon->length;
	my $perc_overlap   = 100 * ( $overlap_length / $ann_length);
	if ( $perc_overlap >= $lower_bound ){
	  $seen_exon3{ $ann_exon }  = 1;
	  $seen_exon3{ $pred_exon } = 1;
	  $count_covered_exons3++;
	  next ANN_EXON;
	}
      }
    }
    }


  print STDERR "EXON COVERAGE ACCORDING TO EXON-OVERLAP >= $lower_bound %\n";
  print STDERR "Total predicted exons: ".scalar(@pred_exons)."\n";
  print STDERR "Total annotated exons: ".scalar(@ann_exons)."\n";
  print STDERR "Found annotated exons: ".$count_covered_exons3."\n";
  
  my $sensitivity3 = $count_covered_exons3/scalar(@ann_exons);
  my $specificity3 = $count_covered_exons3/scalar(@pred_exons);

  print STDERR "               Sensitivity: $sensitivity3\n";
  print STDERR "               Specificity: $specificity3\n";
  print STDERR "\n";
  }
}  

############################################################

=head2

 Title   : _cluster_Exons
 Function: it cluster exons according to exon overlap,
           it returns a Bio::EnsEMBL::SeqFeature, where the sub_SeqFeatures
           are exon_clusters, which are at the same time Bio::EnsEMBL::SeqFeatures,
           whose sub_SeqFeatures are exons
=cut

sub _cluster_Exons{
  my ($self, @exons) = @_;

  # no point if there are no exons!
  return unless ( scalar( @exons) > 0 );   

  # keep track about in which cluster is each exon
  my %exon2cluster;
  
  # main cluster feature - holds all clusters
  my $cluster_list = new Bio::EnsEMBL::SeqFeature; 
  
  # sort exons by start coordinate
  @exons = sort { $a->start <=> $b->start } @exons;

  # Create the first exon_cluster
  my $exon_cluster = new Bio::EnsEMBL::SeqFeature;
  
  # Start off the cluster with the first exon
  $exon_cluster->add_sub_SeqFeature($exons[0],'EXPAND');
  $exon_cluster->strand($exons[0]->strand);    
  $cluster_list->add_sub_SeqFeature($exon_cluster,'EXPAND');
  
  # Loop over the rest of the exons
  my $count = 0;

 EXON:
  foreach my $exon (@exons) {
    if ($count > 0) {
      my $overlap = $self->_exon_Overlap($exon, $exon_cluster);
      
      # Add to cluster if overlap AND if strand matches
      if ( $overlap && ( $exon->strand == $exon_cluster->strand) ) { 
	$exon_cluster->add_sub_SeqFeature($exon,'EXPAND');
      }  
      else {
	# Start a new cluster
	$exon_cluster = new Bio::EnsEMBL::SeqFeature;
	$exon_cluster->add_sub_SeqFeature($exon,'EXPAND');
	$exon_cluster->strand($exon->strand);
		
	# and add it to the main_cluster feature
	$cluster_list->add_sub_SeqFeature($exon_cluster,'EXPAND');	
      }
    }
    $count++;
  }
  return $cluster_list;
}

############################################################

sub match {
  my ($self, $f1,$f2) = @_;
  
  my ($start1,
      $start2,
      $end1,
      $end2,
      $rev1,
      $rev2,
     );

	     # Swap the coords round if necessary
	     if ($f1->start > $f1->end) {
	       $start1 = $f1->end;
	       $end1   = $f1->start;
	       $rev1   = 1;
	     } else {
	       $start1 = $f1->start;
	       $end1   = $f1->end;
	     }
  
  if ($f2->start > $f2->end) {
    $start2 = $f2->end;
    $end2   = $f2->start;
    $rev2   = 1;
  } else {
    $start2 = $f2->start;
    $end2   = $f2->end;
  }
  
  # Now check for an overlap
  if (($end2 > $start1 && $start2 < $end1) ) {
    
    #  we have an overlap so we now need to return 
    #  two numbers reflecting how accurate the span 
    #  is. 
    #  0,0 means an exact match with the exon
    # a positive number means an over match to the exon
    # a negative number means not all the exon bases were matched
    
    my $left  = ($start2 - $start1);
    my $right = ($end1 - $end2);
    
    if ($rev1) {
      my $tmp = $left;
      $left = $right;
      $right = $tmp;
    }
    
    my @overlap;
    
    push (@overlap,1);
    
    push (@overlap,$left);
    push (@overlap,$right);
    
    return @overlap;
  }
}

############################################################

sub gff_file{
  my ($self,$filename) = @_;
  if ($filename){
    $self->{'_gff_file'} = $filename;
  }
  return $self->{'_gff_file'};
}

############################################################

sub toGFF{
  my ($self,$transcript,$gene_type,$label) = @_;
  
  unless( $self->gff_file ){
    print STDERR "Can't print to gff_file if you don't specify one in gff_file()\n";
    return;
  }
  unless( $self->input_id ){
    print STDERR "need to specify the virtual contig in vc()\n";
    return;
  }

  my ( $chrname,$chrstart,$chrend ) = $self->input_id;
  
  my $filename = $self->gff_file;
  
  open(OUTFILE,">>$filename");

  my $genetype;
  if ( $gene_type eq "annotation" ){
    my $gene_adaptor = $self->annotation_db->get_GeneAdaptor;
    $genetype = $gene_adaptor->get_Type_by_Transcript_id($transcript->dbID);
    unless ( $genetype ){
      $genetype = "ann_undetermined";
    }
  }
  elsif ( $gene_type eq "prediction" ){
    my $gene_adaptor = $self->prediction_db->get_GeneAdaptor;
    $genetype = $gene_adaptor->get_Type_by_Transcript_id($transcript->dbID);
    unless ( $genetype ){
      $genetype = "pred_undetermined";
    }
  }
  else{
    $genetype = "undetermined";
  }
 
  
  my $trans_id;
  if ( $transcript->stable_id ){
    $trans_id = $transcript->stable_id;
  }
  elsif ( $transcript->dbID ){
    $trans_id = $transcript->dbID;
  }
  elsif( $transcript->temporary_id ){
    $trans_id = $transcript->temporary_id;
  }
  else{
    $trans_id = "unidentified";
  }
  
  if ($label){  
    $trans_id .= "_".$label;
  }
  
  #print STDERR "gene: $gene_type, type: $genetype, transcript_id: $id\n";
  
  foreach my $exon ( $transcript->get_all_Exons ){
    my $strand_label;
    if ( $exon->strand == 1 ){
      $strand_label = "+";
    }
    elsif( $exon->strand == -1 ){
      $strand_label = "-";
    }
    else{
      $strand_label = "+";
    }
    
    my $exon_id;
    if ( $exon->stable_id ){
      $exon_id = $exon->stable_id;
    }
    elsif ( $exon->dbID ){
      $exon_id = $exon->dbID;
    }
    elsif( $exon->temporary_id ){
      $exon_id = $exon->temporary_id;
    }
    else{
      $exon_id = "unidentified";
    }
    
    print OUTFILE $exon_id
      ."\t".$genetype
	."\texon" 
	  ."\t".($chrstart+$exon->start)
	    ."\t".($chrstart+$exon->end) 
	      ."\t100"
		."\t".$strand_label
		  ."\t".$exon->phase 
		    ."\t". $trans_id
		      ."\n";
  }
  close(OUTFILE);
}


############################################################

sub annotation_db{
  my ($self,$db)=@_;
  if ($db){
    $self->{'_annotation_db'} = $db;
  }
  return $self->{'_annotation_db'};
}

############################################################

sub prediction_db{
  my ($self,$db)=@_;
  if ($db){
    $self->{'_prediction_db'} = $db;
  }
  return $self->{'_prediction_db'};
}

############################################################


1;

