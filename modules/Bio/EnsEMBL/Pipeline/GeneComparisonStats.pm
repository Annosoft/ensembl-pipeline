#
# BioPerl module for Bio::EnsEMBL::Pipeline::GeneComparisonStats
#
# Cared for by Simon Kay <sjk@sanger.ac.uk>
#
# Copyright Simon Kay
#
# You may distribute this module under the same terms as perl itself

# POD documentation - main docs before the code

=head1 NAME

Bio::EnsEMBL::Pipeline::GeneComparisonStats - Comparison of two clones

=head1 SYNOPSIS

@{$self->{'_standardGenes'}} is an array of standard genes found on the clone
given as the $standard parameter when a new object of this class is created.
These are compared to @{$self->{'_predictorGenes'}} which is an array of 
predictor genes found on the clone given as the $predictor parameter when 
a new object of this class is created.

=head1 DESCRIPTION

This module represents a represents the top-level class used for gene comparison.
A new object of this class should be created for each comparison between a pair of
clones. It is a specialisation of Bio::Root::RootI. The constructor (new method) takes two
parameter which should be references to the standard and predictor clones. The constructor
finds all the genes on these clones and stores them in the @{$self->{'_standardGenes'}} and
@{$self->{'_predictorGenes'}} properties. Various methods perform comparisons between these 
arrays of genes by in turn creating objects of the class Bio::EnsEMBL::Pipeline::GeneCompare 
and calling appropriate methods on these. 

A true positive (TP) prediction is one that correctly predicts the presence of a feature.
A false positive (FP) prediction incorrectly predicts the presence of a feature. A false 
negative (FN) prediction fails to predict the presence of a feature that actually exits.
The sensitivity of a prediction is defined as TP/(TP + FN) and may be thought of as a
measure of how successful the prediction is at finding things that are really there. The
specificity is defined as TP/(TP + FP) and can be thought of a measure of how careful a tool
is about not predicting things that aren't really there. The sensitivity and specificity 
that the predictor clone predicts the standard clone are calculated at the gene, exon and base level. 

Various scores are also calculated. At the gene level these are the missed gene, wrong gene,
split gene and joined gene scores. Also available are the missed and wrong exon scores.
The results of the comparison are obtained by calling the appropriate "get" methods or all 
the results in one string is returned by calling the getGeneComparisonStats method.


=head1 CONTACT

Ensembl - ensembl-dev@ebi.ac.uk

=head1 APPENDIX

=cut



package Bio::EnsEMBL::Pipeline::GeneComparisonStats;

use strict;
use vars qw(@ISA);
use Bio::EnsEMBL::DB::CloneI;
use Bio::Root::RootI;
use Bio::EnsEMBL::Pipeline::GeneCompare;

@ISA = qw(Bio::Root::RootI);

=head2 new

 Title   : new
 Usage   : GeneComparisonStats->new()
 Function: Constructor
 Example : 
 Returns : Reference to an object
 Args    : 

=cut

sub new {
    my ($class, @args) = @_;
    my $self = bless {}, $class;

    my ($standard, $predictor) = $self->_rearrange([qw(STANDARD PREDICTOR)],@args);

    ($standard && $standard->isa('Bio::EnsEMBL::DB::CloneI')) 
        || $self->throw("GeneComparisonStats requires a standard object which implements CloneI");
    ($predictor && $predictor->isa('Bio::EnsEMBL::DB::CloneI')) 
        || $self->throw("GeneComparisonStats requires a predictor object which implements CloneI");

    @{$self->{'_standardGenes'}} = $standard->get_all_Genes();
    @{$self->{'_predictorGenes'}} = $predictor->get_all_Genes();

    return $self;
}



=head2 _getStandardGenes

 Title   : _getStandardGenes
 Usage   : $obj->_getStandardGenes
 Function: 
 Example : 
 Returns : Array of standard genes
 Args    : 


=cut

sub _getStandardGenes {
    my ($self) = @_;
    
    return @{$self->{'_standardGenes'}}; 
}



=head2 _getPredictorGenes

 Title   : _getPredictorGenes
 Usage   : $obj->_getPredictorGenes
 Function: 
 Example : 
 Returns : Array of predictor genes
 Args    : 


=cut

sub _getPredictorGenes {
    my ($self) = @_;
    
    return @{$self->{'_predictorGenes'}}; 
}


=head2 getGeneSpecificity

 Title   : getGeneSpecificity
 Usage   : $obj->getGeneSpecificity()
 Function: The specificity at which the predictor is able to correctly identify
            and asemble all of a gene's exons. 
 Example : 
 Returns : Integer
 Args    : None

=cut

sub getGeneSpecificity {
    my ($obj) = @_;
    
    unless ($obj->{'_geneSpecificity'}) {
        $obj->_genePredictions();       
    }
    
    return $obj->{'_geneSpecificity'};
}



=head2 getGeneSensitivity

 Title   : getGeneSensitivity
 Usage   : $obj->getGeneSensitivity()
 Function: The sensitivity at which the predictor is able to correctly identify
            and asemble all of a gene's exons. 
 Example : 
 Returns : Integer
 Args    : None

=cut

sub getGeneSensitivity {
    my ($obj) = @_;
    
    unless ($obj->{'_geneSensitivity'}) {
        $obj->_genePredictions();
    }
    
    return $obj->{'_geneSensitivity'};
}



=head2 _genePredictions

 Title   : _genePredictions
 Usage   : $obj->_genePredictions()
 Function: Calculates the specificity and sensitivity at which the predictor is able to correctly identify
            and asemble all of each standard gene's exons. They are both calculated at the same time because almost
            certainly they will both be required and half the data for each calculation is the same.
            If all the exons of a standard gene are identified and every intron-exon boundary is 
            correct, i.e. each exon has an exact overlap, the gene is a true positive; otherwise
            a false negative. The false positives are then found separately by counting any predictor genes that 
            are not exactly matched by the standard set.
 Example : 
 Returns : Nothing
 Args    : None

=cut

sub _genePredictions {
    my ($self) = @_;
    
    my $truePositive = 0;
    my $falsePositive = 0;
    my $falseNegative = 0;    
    my $comparer = new Bio::EnsEMBL::Pipeline::GeneCompare($self->_getPredictorGenes);
    
    foreach my $standardGene ($self->_getStandardGenes) {
        $comparer->setStandardGene($standardGene);
        if ($comparer->isExactlyMatched()) {
            $truePositive++;
        } else {
            $falseNegative++;
        }
    }
    
    # If there are no true positives we don't need to calculate the false positives
    if ($truePositive == 0) {
        $self->{'_geneSpecificity'} = 0;  
        $self->{'_geneSensitivity'} = 0;
        return;
    }
         
    $comparer = new Bio::EnsEMBL::Pipeline::GeneCompare($self->_getStandardGenes);
    
    foreach my $predictorGene ($self->_getPredictorGenes) {
    
        $comparer->setStandardGene($predictorGene);
        unless ($comparer->isExactlyMatched()) {
            $falsePositive++;
        } 
       # $falsePositive += $comparer->isMissed();
    }  
                 
    $self->{'_geneSpecificity'} = $truePositive / ($truePositive + $falsePositive);  
    $self->{'_geneSensitivity'} = $truePositive / ($truePositive + $falseNegative);       
}



=head2 getMissedGeneScore

 Title   : getMissedGeneScore
 Usage   : $obj->getMissedGeneScore()
 Function: A gene is considered missed if none of its exons are overlapped by a predicted gene.
            If necessary this is calculated by a call to _getMissed with each standard gene being 
            compared against all the predictor genes.
 Example : 
 Returns : Integer - Frequency at which the predictor completely fails to identify an gene. 
 Args    : None

=cut

sub getMissedGeneScore {
    my ($self) = @_;
    
    unless ($self->{'_missedGeneScore'}) { 
        my @array1 = $self->_getStandardGenes;
        my @array2 = $self->_getPredictorGenes;                  
        $self->{'_missedGeneScore'} = $self->_getMissedGene(\@array1, \@array2); 
    }
    
    return $self->{'_missedGeneScore'};
}



=head2 getWrongGeneScore

 Title   : getWrongGeneScore
 Usage   : $obj->getWrongGeneScore()
 Function: A prediction is considered wrong if none of its exons are overlapped by a gene from the standard set.
            If necessary this is calculated by a call to _getMissed with each predictor gene being 
            compared against all the standard genes. 
 Example : 
 Returns : Integer - Frequency at which the predictor incorrectly identifies a gene.  
 Args    : None

=cut

sub getWrongGeneScore {
    my ($self) = @_;
    
    unless ($self->{'_wrongGeneScore'}) { 
        my @array1 = $self->_getPredictorGenes;
        my @array2 = $self->_getStandardGenes;                  
        $self->{'_wrongGeneScore'} = $self->_getMissedGene(\@array1, \@array2);
    }
    
    return $self->{'_wrongGeneScore'};
}



=head2 _getMissedGene

 Title   : _getMissedGene
 Usage   : $obj->_getMissedGene()
 Function: Calculate the frequency at which the genes in array2 completely fails to 
            identify a gene in array1. A gene is considered missed if none of
            its exons are overlapped by a predicted gene.
 Example : 
 Returns : Integer - Missed gene frequency
 Args    : Two arrays of genes

=cut

sub _getMissedGene {
    my ($self, $array1, $array2) = @_;
    
    my $comparer = new Bio::EnsEMBL::Pipeline::GeneCompare(@$array2);
    my $missed = 0;
    my $count = 0;
        
    foreach my $gene (@$array1) {  
        $comparer->setStandardGene($gene);
        $missed += $comparer->isMissed();
        $count++;
    }
          
    return $missed / $count;
}



=head2 getSplitGeneScore

 Title   : getSplitGeneScore
 Usage   : $obj->getSplitGeneScore()
 Function: The frequency at which the predictor incorrectly splits a gene's 
            exons into multiple genes. A gene from the standard set is 
            considered split if it overlaps more than one predicted gene.
            The score is defined as the sum of the number of predicted genes
            that overlap each standard gene divided by the number of 
            standard genes that were split.
 Example : 
 Returns : Integer - split gene frequency
 Args    : None

=cut

sub getSplitGeneScore {
    my ($self) = @_;
    
    unless ($self->{'_splitGeneScore'}) {
        my @array1 = $self->_getStandardGenes;
        my @array2 = $self->_getPredictorGenes;        
        $self->{'_splitGeneScore'} = $self->_getMulitipleOverlaps(\@array1, \@array2);
    }
    
    return $self->{'_splitGeneScore'};
}



=head2 getJoinedGeneScore

 Title   : getJoinedGeneScore
 Usage   : $obj->getJoinedGeneScore()
 Function: The frequency at which the predictor incorrectly assembles multiple
            genes' exons into a single gene. A predicted gene is considered 
            joined if it overlaps more than one gene in the standard set.
            The score is defined as the sum of the number of standard genes that
            overlap each predicted genes divided by the number of predicted genes
            that were joined.
 Example : 
 Returns : Integer - joined gene frequency
 Args    : None

=cut

sub getJoinedGeneScore {
    my ($self) = @_;
    
    unless ($self->{'_joinedGeneScore'}) {
        my @array1 = $self->_getPredictorGenes;
        my @array2 = $self->_getStandardGenes;    
        $self->{'_joinedGeneScore'} = $self->_getMulitipleOverlaps(\@array1, \@array2);
    }
    
    return $self->{'_joinedGeneScore'};
}



=head2 _getMulitipleOverlaps

 Title   : _getMulitipleOverlaps
 Usage   : $obj->_getMulitipleOverlaps()
 Function: Calculates the sum of the total number of genes from array2 that overlap each gene from array1
            and the number of genes in array2 that overlap more than one gene in array1.
 Example : 
 Returns : Integer - The ratio of the number of overlaps to the number of non-multiples.
 Args    : 

=cut

sub _getMulitipleOverlaps {
    my ($self, $array1, $array2) = @_;
    
    my $comparer = new Bio::EnsEMBL::Pipeline::GeneCompare(@$array2);
    my $multiples = 0;
    my $overlaps = 0;
        
    foreach my $gene (@$array1) {
       $comparer->setStandardGene($gene);
       $overlaps += $comparer->getGeneOverlapCount();            
    }
    
    $comparer = new Bio::EnsEMBL::Pipeline::GeneCompare(@$array1);
    
    foreach my $gene (@$array2) {
       $comparer->setStandardGene($gene);
       if ($comparer->getGeneOverlapCount() > 1) {
           $multiples++;
       }
    }
     
    if ($overlaps == 0) {
        return 0;
    } 
    return ($overlaps + $multiples) / $overlaps;
}


=head2 getExonSpecificity

 Title   : getExonSpecificity
 Usage   : $obj->getExonSpecificity()
 Function: The specificity at which the predictor identifies exons 
            and correctly recognises their boundaries.
 Example : 
 Returns : Integer
 Args    : None

=cut

sub getExonSpecificity {
    my ($obj) = @_;
    
    unless ($obj->{'_exonSpecificity'}) {
        $obj->_exonPredictions();
    }
    
    return $obj->{'_exonSpecificity'};
}


=head2 getExonSensitivity

 Title   : getExonSensitivity
 Usage   : $obj->getExonSensitivity()
 Function: The sensitivity at which the predictor identifies exons 
            and correctly recognises their boundaries.
 Example : 
 Returns : Integer
 Args    : None


=cut

sub getExonSensitivity {
    my ($obj) = @_;
    
    unless ($obj->{'_exonSensitivity'}) {
        $obj->_exonPredictions();
    }
    
    return $obj->{'_exonSensitivity'};
}



=head2 _exonPredictions

 Title   : _exonPredictions
 Usage   : $obj->_exonPredictions()
 Function: Calculates the specificity and sensitivity at which the predictor is able to correctly identify
            exons and correctly recognises their boundaries. They are both calculated at the same time because almost
            certainly they will both be required and half the data for each calculation is the same.
            If a standard exon is exactly overlapped by a predictor exon it is a true positive; otherwise
            a false negative. The false positives are then found separately by counting any predictor exons which 
            are missing from the standard set.
 Example : 
 Returns : Nothing
 Args    : None

=cut

sub _exonPredictions {
    my ($self) = @_;
    
    my $truePositive = 0;
    my $falsePositive = 0;
    my $falseNegative = 0;    
    my $comparer = new Bio::EnsEMBL::Pipeline::GeneCompare($self->_getPredictorGenes);
    
    foreach my $standardGene ($self->_getStandardGenes) {
        $comparer->setStandardGene($standardGene);
        my ($tP, $fN) = $comparer->getExactOverlapRatio(); 
        $truePositive += $tP;
        $falseNegative += $fN;        
    }
    
    $comparer = new Bio::EnsEMBL::Pipeline::GeneCompare($self->_getStandardGenes);
    
    foreach my $predictorGene ($self->_getPredictorGenes) {
        $comparer->setStandardGene($predictorGene);
        my ($missed, $count) = $comparer->getMissed(); 
        $falsePositive += $missed;
    }    
            
    $self->{'_exonSpecificity'} = $truePositive / ($truePositive + $falsePositive);  
    $self->{'_exonSensitivity'} = $truePositive / ($truePositive + $falseNegative);       
}



=head2 getMissedExonScore

 Title   : getMissedExonScore
 Usage   : $obj->getMissedExonScore()
 Function: The frequency at which the predictor completely fails to 
            identify an exon (no prediction or overlap). 
 Example : 
 Returns : Integer
 Args    : None


=cut

sub getMissedExonScore {
    my ($self) = @_;
    
    unless ($self->{'_missedExonScore'}) {
        my @array1 = $self->_getStandardGenes;
        my @array2 = $self->_getPredictorGenes; 
                 
        $self->{'_missedExonScore'} = $self->_getMissedExon(\@array1, \@array2); 
    }
    
    return $self->{'_missedExonScore'};
}



=head2 getWrongExonScore

 Title   : getWrongExonScore
 Usage   : $obj->getWrongExonScore()
 Function: The frequency at which the predictor identifies an exon
            that has no overlap with any exon from the standard.  
 Example : 
 Returns : Integer - Wrong exon score
 Args    : None


=cut

sub getWrongExonScore {
    my ($self) = @_;
    
    unless ($self->{'_wrongExonScore'}) {
        my @array1 = $self->_getPredictorGenes;
        my @array2 = $self->_getStandardGenes;           
        $self->{'_wrongExonScore'} = $self->_getMissedExon(\@array1, \@array2);
    }
    
    return $self->{'_wrongExonScore'};
}



=head2 _getMissedExon

 Title   : _getMissedExon
 Usage   : $obj->_getMissedExon()
 Function: The frequency at which the genes in array2 completely fails to 
            identify a gene in array1. A gene is considered missed if none of
            its exons are overlapped by a predicted gene.
 Example : 
 Returns : Integer
 Args    : Two arrays of genes

=cut

sub _getMissedExon {
    my ($self, $array1, $array2) = @_;
    
    my $comparer = new Bio::EnsEMBL::Pipeline::GeneCompare(@$array2);
    my $missed = 0;
    my $count = 0;
        
    foreach my $gene (@$array1) {  
        $comparer->setStandardGene($gene);
        my ($m, $c) = $comparer->getMissed();   
        $count += $c;
        $missed += $m;
    }          
    return $missed / $count;
}



=head2 getBaseSpecificity

 Title   : getBaseSpecificity
 Usage   : $obj->getBaseSpecificity()
 Function: The specificity at which the predictor correctly labels
            a base in the genomic sequence as being part of each gene.
            This rewards predictors that get most of each gene correct
            and penalises those that miss large parts.
 Example : 
 Returns : Integer
 Args    : None


=cut

sub getBaseSpecificity {
    my ($self) = @_;
    
    unless ($self->{'_baseSpecificity'}) {
        $self->_basePredictions();
    }
    return $self->{'_baseSpecificity'};
}



=head2 getBaseSensitivity

 Title   : getBaseSensitivity
 Usage   : $obj->getBaseSensitivity()
 Function: The sensitivity at which the predictor correctly labels
            a base in the genomic sequence as being part of each gene.
            This rewards predictors that get most of each gene correct
            and penalises those that miss large parts.
 Example : 
 Returns : Integer
 Args    : None


=cut

sub getBaseSensitivity {
    my ($self) = @_;
    
    unless ($self->{'_baseSensitivity'}) {
        $self->_basePredictions();
    }
    return $self->{'_baseSensitivity'};
}



=head2 _basePredictions

 Title   : _basePredictions
 Usage   : $obj->_basePredictions()
 Function: Calculates the specificity and sensitivity at which the predictor is able to correctly 
            identify exons and correctly recognises their boundaries. They are both calculated at 
            the same time because almost certainly they will both be required and half the data for 
            each calculation is the same. If a standard exon is exactly overlapped by a predictor 
            exon it is a true positive; otherwise a false negative. The false positives are then 
            found separately by counting any predictor exons which are missing from the standard set.
 Example : 
 Returns : Nothing
 Args    : None

=cut

sub _basePredictions {
    my ($self) = @_;
    
    my $truePositive = 0;
    my $falsePositive = 0;
    my $falseNegative = 0; 
    
    # Create a hash of all the predictor exons with no duplicates.
    my %nonOverlappingExons = ();    
    foreach my $gene ($self->_getPredictorGenes) {
        foreach ($gene->each_unique_Exon()) {
            $nonOverlappingExons{$_} = $_;
        }
    }
                 
    my $comparer = new Bio::EnsEMBL::Pipeline::GeneCompare($self->_getPredictorGenes);
    
    foreach my $standardGene ($self->_getStandardGenes) {
        $comparer->setStandardGene($standardGene);
        
        # Remove overlapping predictor exons from the nonoverlapping hash
        my @overlaps = $comparer->getExonOverlaps();         
        foreach (@overlaps) {    
            delete $nonOverlappingExons{$_};
        } 
        
        my ($tP, $fP, $fN) = $comparer->getBaseOverlaps(\@overlaps); 
        $truePositive += $tP;
        $falsePositive += $fP;
        $falseNegative += $fN;         
                      
    }  
    
    # The total length of all the non overlapping predictors is also false positive.
    foreach (keys %nonOverlappingExons) {
        $falsePositive += $nonOverlappingExons{$_}->length();                    
    }     
    
    if ($truePositive == 0) {
        $self->{'_baseSpecificity'} = 0;
        $self->{'_baseSensitivity'} = 0;
    } else {      
        $self->{'_baseSpecificity'} = $truePositive / ($truePositive + $falseNegative);  
        $self->{'_baseSensitivity'} = $truePositive / ($truePositive + $falsePositive);       
    }
}



=head2 getGeneComparisonStats

 Title   : getGeneComparisonStats
 Usage   : $obj->getGeneComparisonStats()
 Function: Calculates all the stats and returns as a user-friendly string.
 Example : 
 Returns : String
 Args    : None


=cut

sub getGeneComparisonStats {
    my ($self) = @_;
    
    return  "Gene level sensitivity: ", $self->getGeneSensitivity(), "\n",
            "Gene level specificity: ", $self->getGeneSpecificity(), "\n",
            "Missed gene score: ", $self->getMissedGeneScore(), "\n",
            "Wrong gene score: ", $self->getWrongGeneScore(), "\n",
            "Joined gene score: ", $self->getJoinedGeneScore(), "\n",
            "Split gene score: ", $self->getSplitGeneScore(), "\n",
            "Exon level sensitivity: ", $self->getExonSensitivity(), "\n",
            "Exon level specificity: ", $self->getExonSpecificity(), "\n",
            "Missed exon score: ", $self->getMissedExonScore(), "\n",
            "Wrong exon score: ", $self->getWrongExonScore(), "\n",            
            "Base level sensitivity: ", $self->getBaseSensitivity(), "\n",
            "Base level specificity: ", $self->getBaseSpecificity(), "\n";
}

1;
