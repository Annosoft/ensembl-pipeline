#!/usr/local/ensembl/bin/perl


=head1 NAME

run_GeneComparison

=head1 SYNOPSIS
 
=head1 DESCRIPTION

reads the config options from .../ensembl/modules/Bio/EnsEMBL/Utils/GeneComparison_conf.pl
and reads as input an input_id in the style of other Runnables, i.e. -input_id chr_name.chr_start-chr_end

=head1 OPTIONS

    -input_id  The input id

=cut

use strict;  
use diagnostics;
use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Utils::GeneComparison;
use Getopt::Long;

## load all the parameters
use Bio::EnsEMBL::Utils::GeneCompConf;


my $host1   = $DBHOST1;
my $dbname1 = $DBNAME1;
my $path1   = $PATH1;
my $type1   = $GENETYPES1;
my $user1   = $DBUSER1;

my $host2   = $DBHOST2;
my $dbname2 = $DBNAME2;
my $path2   = $PATH2;
my $type2   = $GENETYPES2;
my $user2   = $DBUSER2;

my $runnable;
my $input_id;
my $write  = 0;
my $check  = 0;
my $params;
my $pepfile;

# can override db options on command line
&GetOptions( 
	     'input_id:s'  => \$input_id,

	     );
	     
die "No input id entered" unless defined ($input_id);
    
# get genomic region 
my $chr      = $input_id;
$chr         =~ s/\.(.*)-(.*)//;
my $chrstart = $1;
my $chrend   = $2;

unless ( $chr && $chrstart && $chrend ){
       print STDERR "bad input_id option, try something like chr20.1-5000000\n";
}

# connect to the databases 
print STDERR "Connecting to database $dbname1 : $host1 : $user1 \n";
my $db1= new Bio::EnsEMBL::DBSQL::DBAdaptor(-host  => $host1,
					    -user  => $user1,
					    -dbname=> $dbname1);


print STDERR "Connecting to database $dbname2 : $host2 : $user2 \n";
my $db2= new Bio::EnsEMBL::DBSQL::DBAdaptor(-host  => $host2,
					    -user  => $user2,
					    -dbname=> $dbname2);


print STDERR "Connected to database $dbname2\n";

# use different golden paths
$db1->static_golden_path_type($path1); 
$db2->static_golden_path_type($path2); 

my $sgp1 = $db1->get_StaticGoldenPathAdaptor;
my $sgp2 = $db2->get_StaticGoldenPathAdaptor;

# get a virtual contig with a piece-of/entire chromosome #
my ($vcontig1,$vcontig2);

print STDERR "Fetching region $chr, $chrstart - $chrend\n";
$vcontig1 = $sgp1->fetch_VirtualContig_by_chr_start_end($chr,$chrstart,$chrend);
$vcontig2 = $sgp2->fetch_VirtualContig_by_chr_start_end($chr,$chrstart,$chrend);

# get the genes of type @type1 and @type2 from $vcontig1 and $vcontig2, respectively #
my (@genes1,@genes2);

foreach my $type ( @{ $type1 } ){
  print STDERR "Fetching genes of type $type\n";
  my @more_genes = $vcontig1->get_Genes_by_Type($type);
  push ( @genes1, @more_genes ); 
  print STDERR scalar(@more_genes)." genes found\n";
}

foreach my $type ( @{ $type2 } ){
  print STDERR "Fetching genes of type $type\n";
  my @more_genes = $vcontig2->get_Genes_by_Type($type);
  push ( @genes2, @more_genes ); 
  print STDERR scalar(@more_genes)." genes found\n";
}

# get a GeneComparison object 
my $gene_comparison = Bio::EnsEMBL::Utils::GeneComparison->new(\@genes1, \@genes2);
# as convention, we put first the annotated (or benchmark) genes and second the predicted genes
# and the comparison methods refer to the second list with respect to the first one

## As an example, we get the number of exons per percentage overlap using coding exons only
#my %coding_statistics =  $gene_comparison->get_Coding_Exon_Statistics;

## You could also do it for all exons, coding and non-conding
#
# my %statistics = $gene_comparison->get_Exon_Statistics;
#

# The hashes hold the number of occurences as values and integer percentage overlap as keys
# these methods also print out the start and end coding exon overlaps

# We can produce a histogram

#my @values = values ( %coding_statistics );
#@values = sort {$b <=> $a} @values;

#print "Percentage overlap : Number of overlapping coding exons\n";
#for (my $i=1; $i<= 100; $i++){
#  if ( $coding_statistics{$i} ){
#    print $i." :\t".$coding_statistics{$i}."\t".print_row ($coding_statistics{$i})."\n";
#  }
#  else{
#    print $i." :\n";
#  }
#}

#sub print_row {
#  my $size = int( shift @_ );
#  $size = int( log( 1000*$size/($values[0]) ) ); # tweak this to re-scale it as you wish
#  my $row='';
#  for (my $i=0; $i<$size; $i++){
#    $row .='*';
#  }
#  return $row;
#}

#########################################################
#
#  Other examples of the potential use of GeneComparison
#
#########################################################

## cluster the genes we have passed to $gene_comparison

my @gene_clusters    = $gene_comparison->cluster_Genes;

my @unclustered = $gene_comparison->unclustered_Genes;


###cluster the transcripts of the genes in _gene_array1 and gene_array2 directly
# 
my @clusters = $gene_comparison->cluster_Transcripts;
#
## this returns an array of TranscriptCluster objects as well

# print the clusters 
print "Number of clusters: ".scalar( @clusters )."\n";

 my $count=1;
 foreach my $cluster (@clusters){
   print "Cluster $count:\n";
   print $cluster->to_String."\n";
   $count++;
 }

#$count=1;
#print "Unmatched genes: ".scalar( @unclustered )."\n";

#foreach my $cluster (@unclustered){
#print "Unclustered $count:\n";
#print $cluster->to_String."\n";
#$count++;
#}


$gene_comparison->compare_Exons(\@gene_clusters);


#$gene_comparison->find_missing_coding_Exons(\@gene_clusters);

#$gene_comparison->find_overpredicted_coding_Exons(\@gene_clusters);

# get the overpredicted exons ( those in @genes2 which are missing in @genes2 )
#$gene_comparison->find_overpredicted_Exons(\@clusters);

## get the list of unmatched genes
# 
# my ($unmatched1,$unmatched2) = $gene_comparison->get_unmatched_Genes;
#
## this returns an array of GeneCluster objects as well, but only containing the unmatched ones



## get the list of fragmented genes
#
# my @fragmented = $gene_comparison->get_fragmented_Genes (@clusters);
#
## this returns an array of GeneCluster objects as well, but only containing the fragmented ones



## cluster the transcripts using the gene clusters obtained above:
#
# my @transcript_clusters = $gene_comparison->cluster_Transcripts_by_Gene(@clusters);
#
## this returns an array of TranscriptCluster objects, 
## which can be printed as we did with the GeneCluster objects above








