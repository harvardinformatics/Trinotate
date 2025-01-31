#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
use lib ("$FindBin::Bin/../PerlLib");

use Data::Dumper;
use Sqlite_connect;
use Trinotate;

use Getopt::Long qw(:config no_ignore_case bundling pass_through);

my $usage = <<__EOUSAGE__;

##################################################################
#
#  --sqlite <string>          name of sqlite database
#
#  -E <float>                 maximum E-value for reporting best blast hit
#                             and associated annotations.
#
#  --pfam_cutoff <string>     'DNC' : domain noise cutoff (default)
#                             'DGC' : domain gathering cutoff
#                             'DTC' : domain trusted cutoff
#                             'SNC' : sequence noise cutoff
#                             'SGC' : sequence gathering cutoff
#                             'STC' : sequence trusted cutoff
#
#  --incl_pep                 include peptide sequence in output
#  --incl_trans               include transcript sequence in output
#
#  --help|h                   this menu
#
#  --verbose                  run verbosely, indicate SQL queries
#
##################################################################

__EOUSAGE__

    ;

my $Evalue_cutoff = 1e-5;
my $help_flag;
my $pfam_cutoff = "DNC";
my $sqlite_db;

my $include_pep = 0;
my $include_trans = 0;

our $SEE;

&GetOptions( 
    'help|h' => \$help_flag,
    'sqlite=s' => \$sqlite_db,
    'E=f' => \$Evalue_cutoff,
    'pfam_cutoff=s' => \$pfam_cutoff,
    
    'incl_pep' => \$include_pep,
    'incl_trans' => \$include_trans,
    'verbose' => \$SEE,

    );

if ($help_flag) {
    die $usage;
}

unless ($sqlite_db) {
    die $usage;
}

unless ($pfam_cutoff =~ /^(DNC|DGC|DTC|SNC|SGC|STC)$/) {
    die $usage . "\n\nError, do not recognize pfam_cutoff specified as [$pfam_cutoff]\n\n";
}

main: {

    unless (-s $sqlite_db) {
        die "Error, cannot find sqlite database: $sqlite_db ";
    }
    
    my $dbproc = &connect_to_db($sqlite_db);
    
    my @results = &do_sql_2D($dbproc, "select gene_id, transcript_id from Transcript");
    
    # print header

    my @header = ("#gene_id", "transcript_id", "sprot_Top_BLASTX_hit", "TrEMBL_Top_BLASTX_hit", "RNAMMER", 
                  "prot_id", "prot_coords", 
                  "sprot_Top_BLASTP_hit", "TrEMBL_Top_BLASTP_hit", "Pfam", "SignalP", "TmHMM", 
                  "eggnog", "gene_ontology_blast", "gene_ontology_pfam", 
                  "transcript", "peptide");
    
    print join("\t", @header) . "\n";
    
    foreach my $result (@results) {
        
        my ($gene_id, $trans_id) = @$result;

        my $query = "select orf_id, strand, lend, rend from ORF where transcript_id = ?";
        my @orf_results = &do_sql_2D($dbproc, $query, $trans_id);

        my $BLASTX_info_sprot = &get_blast_results($dbproc, $trans_id, "blastx", "Swissprot");
        my $BLASTX_info_trembl = &get_blast_results($dbproc, $trans_id, "blastx", "TrEMBL");

        my $rnammer_txt = &get_RNAMMER_info($dbproc, $trans_id);

        my $trans_seq = ($include_trans) ? &get_transcript($dbproc, $trans_id) : ".";
        
        if (@orf_results) {
            foreach my $orf_result (@orf_results) {
                my ($prot_id, $strand, $lend, $rend) = @$orf_result;
                
                my $BLASTP_info_sprot = &get_blast_results($dbproc, $prot_id, "blastp", "Swissprot");
                my $BLASTP_info_trembl = &get_blast_results($dbproc, $prot_id, "blastp", "TrEMBL");
                
                my $pfam_info = &get_pfam_info($dbproc, $prot_id);
                my $gene_ontology_pfam = &get_gene_ontology_from_pfam_hit($dbproc, $pfam_info);
                
                my $signalP_info = &get_signalP_info($dbproc, $prot_id);
                
                my $TmHMM_info = &get_TmHMM_info($dbproc, $prot_id);
                
                my $eggnog = &get_eggnog_info_from_blast_hit($dbproc, $BLASTP_info_sprot);
                
                my $gene_ontology_blast = &get_gene_ontology_from_blast_hit($dbproc, $BLASTP_info_sprot);
                
                my $peptide = ($include_pep) ? &get_peptide($dbproc, $prot_id) : ".";
                
                my @fields = ($gene_id, $trans_id, $BLASTX_info_sprot, $BLASTX_info_trembl, $rnammer_txt, 
                              $prot_id, "$lend-$rend\[$strand]",
                              $BLASTP_info_sprot, $BLASTP_info_trembl, $pfam_info, $signalP_info, $TmHMM_info, 
                              $eggnog, $gene_ontology_blast, $gene_ontology_pfam, 
                              $trans_seq, $peptide);
                
                print join("\t", @fields) . "\n";
                
            }
        }
        else {


            my $eggnog = &get_eggnog_info_from_blast_hit($dbproc, $BLASTX_info_sprot);
            
            my $gene_ontology_blast = &get_gene_ontology_from_blast_hit($dbproc, $BLASTX_info_sprot);


            print join("\t", $gene_id, $trans_id, $BLASTX_info_sprot, $BLASTX_info_trembl, $rnammer_txt,
                       ".", ".", 
                       ".", ".", ".", ".", ".",
                       $eggnog, $gene_ontology_blast, ".", 
                       $trans_seq, ".") . "\n";
        }
    }
    
    exit(0);


}

####
sub get_transcript {
    my ($dbproc, $trans_id) = @_;

    my $query = "select sequence from Transcript where transcript_id = \"$trans_id\"";
    my $sequence = &very_first_result_sql($dbproc, $query);

    return($sequence);
}

####
sub get_peptide {
    my ($dbproc, $prot_id) = @_;

    my $query = "select peptide from ORF where orf_id = \"$prot_id\"";
    my $peptide = &very_first_result_sql($dbproc, $query);

    return($peptide);
}


####
sub get_TmHMM_info {
    my ($dbproc, $id) = @_;

    my $tmhmm_struct = &Trinotate::get_TmHMM_info($dbproc, $id);
    
    if ($tmhmm_struct) {
        my $tmhmm_line = join("^", 
                              $tmhmm_struct->{Score}, 
                              $tmhmm_struct->{PredHel},
                              $tmhmm_struct->{Topology},
            );
        return($tmhmm_line);
    }
    else {
        return(".");
    }
}


####
sub get_signalP_info {
    my ($dbproc, $id) = @_;

    my $sigP_struct = &Trinotate::get_signalP_info($dbproc, $id);
    
    if ($sigP_struct) {
        my $sigP_line = "sigP:" . join("^", 
                                       $sigP_struct->{start},
                                       $sigP_struct->{end},
                                       $sigP_struct->{score},
                                       $sigP_struct->{prediction},
            );
        
        return($sigP_line);
    }
    else {
        return(".");
    }
}


###
sub get_pfam_info {
    my ($dbproc, $id) = @_;

    my @pfam_results = &Trinotate::get_pfam_info($dbproc, $id, $pfam_cutoff);

        
    if (@pfam_results) {
        my @encoded_hits;
        foreach my $result (@pfam_results) {
            my ($pfam_id, $domain, $domain_descr, $start, $end, $evalue) = ($result->{pfam_id},
                                                                            $result->{HMMERDomain},
                                                                            $result->{HMMERTDomainDescription},
                                                                            $result->{QueryStartAlign},
                                                                            $result->{QueryEndAlign},
                                                                            $result->{ThisDomainEvalue});
                        
            my $hit = join("^", $pfam_id, $domain, $domain_descr, "$start-$end", "E:$evalue");
            push (@encoded_hits, $hit);
        }
        
        my $result_line = join("`", @encoded_hits);
        
        return($result_line);
    }
    else {
        return(".");
    }
}




####
sub get_blast_results {
    my ($dbproc, $id, $blast_method, $db) = @_;
    
    my @results = &Trinotate::get_blast_results($dbproc, $id, $Evalue_cutoff, $blast_method, $db);
    
    if (@results) {

        my @encoded_hits;
        
        foreach my $result (@results) {
        
            my ($FullAccession, $UniprotSearchString, $QueryStart, $QueryEnd, 
                $HitStart, $HitEnd, $PercentIdentity, $Evalue) = ($result->{FullAccession},
                                                                  $result->{UniprotSearchString},
                                                                  $result->{QueryStart},
                                                                  $result->{QueryEnd},
                                                                  $result->{HitStart},
                                                                  $result->{HitEnd},
                                                                  $result->{PercentIdentity},
                                                                  $result->{Evalue},
                    );
            
        
            my $taxonomy_string = $result->{TaxonomyString} || "no taxonomy value";
            
            my $description_line = $result->{DescriptionLine} || "no description available";
            
            ## encode the result
            my $ret_val = join("^", $FullAccession, $UniprotSearchString, "Q:$QueryStart-$QueryEnd,H:$HitStart-$HitEnd", "$PercentIdentity%ID", "E:$Evalue", $description_line, $taxonomy_string);
            
            push (@encoded_hits, $ret_val);
        }

        return(join ("`", @encoded_hits));
    }
    else {
        return(".");
    }
    
}


####
sub get_eggnog_info_from_blast_hit {
    my ($dbproc, $blast_info) = @_;

    if ($blast_info eq ".") {
        # no top hit
        return(".");
    }

    my @vals = split(/\^/, $blast_info);
    my $blast_hit_acc = $vals[1];

    my @eggnogs = &Trinotate::get_eggnog_info_from_uniprot_acc($dbproc, $blast_hit_acc);

    if (@eggnogs) {
        my @encoded_hits;

        foreach my $eggnog (@eggnogs) {
            my ($eggnog_acc, $eggnog_descr) = ($eggnog->{eggNOGIndexTerm}, $eggnog->{eggNOGDescriptionValue});
            my $entry = join("^", $eggnog_acc, $eggnog_descr);
            push (@encoded_hits, $entry);
        }

        return(join("`", @encoded_hits));
    }
    else {
        return(".");
    }
}

####
sub get_gene_ontology_from_blast_hit {
    my ($dbproc, $blast_info) = @_;


    if ($blast_info eq ".") {
        # no top hit
        return(".");
    }

    my @vals = split(/\^/, $blast_info);
    my $blast_hit_acc = $vals[1];


    #print STDERR "\n\n****\nRetrieving GeneOntology for $blast_hit_acc\n****\n";



    my @gene_ontology_assignments = &Trinotate::get_gene_ontology_from_uniprot_acc($dbproc, $blast_hit_acc);
    
    if (@gene_ontology_assignments) {
        my @tokens;
        foreach my $result (@gene_ontology_assignments) {
            my ($go_id, $go_namespace, $go_name) = ($result->{id},
                                                    $result->{namespace},
                                                    $result->{name},
                );
            
            my $token = join("^", $go_id, $go_namespace, $go_name);
            push (@tokens, $token);
        }
        my $retval = join("`", @tokens);

        #print STDERR "$retval\n"; die;

        return($retval);
    }
    else {
        return(".");
    }
    
    
}


####
sub get_gene_ontology_from_pfam_hit {
    my ($dbproc, $pfam_info) = @_;


    if ($pfam_info eq ".") {
        # no top hit
        return(".");
    }

    my @pfam_hits = split(/\`/, $pfam_info);
    
    my @all_go_assignments;

    foreach my $pfam_hit (@pfam_hits) {
        
        my @vals = split(/\^/, $pfam_hit);
        my $pfam_acc = $vals[0];
        
        #print STDERR "\n\n****\nRetrieving GeneOntology for $blast_hit_acc\n****\n";
        
        my @gene_ontology_assignments = &Trinotate::get_gene_ontology_from_pfam_acc($dbproc, $pfam_acc);
        
        #print STDERR "GO from pfam: $pfam_acc = " . Dumper(\@gene_ontology_assignments);
                
        if (@gene_ontology_assignments) {
            push (@all_go_assignments, @gene_ontology_assignments);
        }
    }

    if (@all_go_assignments) {
        my %seen;
        
        my @tokens;
        foreach my $result (@all_go_assignments) {
            my ($go_id, $go_namespace, $go_name) = ($result->{id},
                                                    $result->{namespace},
                                                    $result->{name},
                                                    );
            
            if ($seen{$go_id}) { next; }
            $seen{$go_id} = 1;
            
            my $token = join("^", $go_id, $go_namespace, $go_name);
            push (@tokens, $token);
        }
        my $retval = join("`", @tokens);
        
        #print STDERR "$retval\n"; die;
        
        return($retval);
    }
    else {
        return(".");
    }
    
    
}




####
sub get_RNAMMER_info {
    my ($dbproc, $trans_id) = @_;

    my @rnammer_hits = &Trinotate::get_RNAMMER_info($dbproc, $trans_id);

    if (@rnammer_hits) {
 
        my @encoded_rnammer_hits;
        
        foreach my $rnammer_hit (@rnammer_hits) {
            my @fields = ($rnammer_hit->{feature_prediction}, join("-", $rnammer_hit->{feature_start}, $rnammer_hit->{feature_end}));
            
            push (@encoded_rnammer_hits, join("^", @fields));
        }
        
        my $result_line = join("`", @encoded_rnammer_hits);
        return($result_line);
    }
    else {
        return(".");
    }
}
