#!/usr/bin/perl

=pod

ABC -- Allele-specific Binding from ChIP-Seq 

Version 1.3

Mathieu Lupien 
Code Under License Artistic-2.0
August 12, 2014

Written By: Swneke D. Bailey

ABC Identifies potential allele-specific binding events at known heterozygous positions within the aligned reads of a ChiP-Seq experiment. 
ABC requires at a minimum two (2) files a sorted BAM/SAM file of the aligned reads from a ChIP-Seq experiment and a file containing the position, strand and allele
information of heterozygous Single Nucleotide Variants (SNVs), either SNPs and/or Mutations. ABC calls allele-specific binding by identifying a bias in
the distribution of the SNV alleles while attempting to control for potential false positives. If you have genomic sequence data
you can use the allele ratio in the DNA as the expected frequency to control for chromosome copy number.

Usage: perl ABC.pl --align-file <input.sam> --snv-file <snv filename> --out <output filename>

--align-file (Required)
		Specify ChIP-Seq alignment file BAM/SAM.
		Note: the BAM/SAM file must be sorted

--bg (Optional)
		Specify a .bedgraph file capturing the ChIP-Seq signal (shifted read pileups) of the .sam file
		This can be useful to prioritize SNPs with low coverage, since they may fall within centre of the +ve and -ve strand peaks.
		This is caused by short reads and is not necessary longer reads.

--snv-file (Required)
		A tab-delimited text file containing the list of heterozygous SNPs.

                The format of the SNV file is as follows (Do not include the header):

	Example:	SNV_ID	CHR	POSITION	STRAND	REF_ALLELE	OBSERVED_ALLELES	ALLELE_RATIO_DNA
           
	        	rs111	chr1	1111	+	A	A/C	0.5
                	SNV1	chr10	10234	-	C	C/G	0.4

		It is the responsibility of the user to verify the quality of the SNVs (ie Do they pass Hardy-Weinberg equilibrium, etc...).

--out (Optional)
		Specify the ouput file prefix (default ABC).

		(ie. ABC will create two output files ABC.dist and ABC.align)

--min-reads (Optional)
		The minimum number of reads covering the a SNVs (default: 25).
		(ie. ABC will report only those SNPs/Mutations with # reads overlapping them.)

--min-mapq (Optional)
		Set the minimum allowed MAPQ score (default: 0).

--d (Optional)
		Divide chromosomes into segments until reaching d lines for faster retrieval (default: 2000). 
                A large number of SNVs can take a long time to process. You may try to increase the value of d.
		However, very large numbers will not necessarily increase speed.

--mw-thres (Optional)
		P-value threshold for the Mann-Whitney test used to test a bias in the read position between the SNV alleles. (default: 0.05)
		To report all SNVs set this parameter to 0.

--f-thres (Optional) 
		P-value threshold for the Fisher's exact test used to test for a bias between the strand distribution of the SNV alleles. (default: 0.05)
                To report all SNVs set this parameter to 0.

--verbose (Optional)
		Print progress and SNV results summary to screen.	

--help		
		Prints command line options


		***	VISUALIZING SNV RESULTS	***

		Create a figure of the distribution of reads containing a SNV of interest

		This step requires that the ABC has finished running.
		Once ABC is finished a figure can be generated by specifying the output file prefix used in the initial run and the SNV ID as follows:

		perl ABC.pl --out <output filename prefix> --visualize-snv <SNV ID>

=cut

use strict;
use warnings;
use Statistics::R;
use Scalar::Util qw(looks_like_number);
use File::Temp qw(tempfile tempdir);

# SUBROUTINES

# Build index and get chromosome starts
# Does not rely on header - helpful if spliting by chromosomes
sub build_index{

   my $dataFile = shift;
   my $indexFile = shift;
   my $check = shift; # Sam or Bedgraph; 0 equal SAM, 1 equals Bedgraph
   my $bcheck = shift; 

   my $offset = 0;
   my @a=();
   my @b=();
   my $n=0;
   my $n2;
   my %chr=();
   my $cc=2; # chromosome column
   my $rl=50; # read length for .sam
   my @sc=(); # check that .sam is sorted   

   # switch column for bedgraph index
   if($check == 1){
      $cc=0;
   }

   if($bcheck == 1){
      seek($dataFile, 0, 0);
   }  
   
   while (<$dataFile>){
       print $indexFile pack("Q>", $offset); #write index
       $offset = tell($dataFile);
       $n+=1;
       chomp();
       my @line=split(/\t/);
       if($line[0] =~ /@/){
          next;
       }else{

         check_tab_delim(\@line);

         if(!exists $chr{$line[$cc]}){ #obtain chromosome start line positions without header
            $chr{$line[$cc]}=$n;
               push(@a,$line[$cc]);
               push(@b,$n);
               $n2=0;
               if($check != 1){
                 push(@sc, $line[3]);
                 $rl=length($line[9]);
               }
         }else{
            if($check != 1){
               if($n2 <= 100){ #check first 100 lines of chromosome for sorting
                  push(@sc, $line[3]);
                  if($n2 > 0){
                     if($a[$#a] eq $line[$cc] && $sc[$n2 - 1] > $sc[$n2]){
                        print "\nWarning .sam file must be sorted!\n";
                        die;
                     }elsif($a[$#a] ne $line[$cc]){
                        print "\nWarning .sam file must be sorted!\n";
                        die;
              ;    }      
                  }
                  $n2+=1;   
              }
           }   
         }
      }
   }
   if($check == 1){
      return(\@a,\@b, $n);
   }else{
      return(\@a,\@b, $n, $rl);
   }  
}

sub get_file_landmarks_2{
    my $chroms=shift; #@chroms ref
    my $positions=shift; #@positions ref
    my $n=shift; # length of file

    my $fp=0; # Start Position
    my $fn=0; # End Position
    
    my %chrIn=(); # Line Numbers
     
    for(my $i=0; $i<=$#{$chroms}; $i++){
       my $l=0;
       if($i != $#{$chroms}){
          $fp = ${$positions}[$i];
          $fn = ${$positions}[$i + 1] - 1;
       }else{
          $fp = ${$positions}[$i];
          $fn = $n;
       }
       push(@{$chrIn{${$chroms}[$i]}},$fp);  
       push(@{$chrIn{${$chroms}[$i]}},$fn);  
    }
 
  return(\%chrIn);
}

# Split chromosome until SNV is within d lines
sub find_starting_point{
    my $sprt=shift; #@findstart ref
    my $chr=shift; #chromosome
    my $bp=shift; #bp
    my $rlen=shift;
    my $file=shift; # filehandle
    my $index=shift; # index file 
    my $check=shift; # Sam or Bedgraph
    my $d=shift; #number of lines
   
    my $cc=3;
    my $rshift=$bp - (2 * $rlen) - 1;
    if($rshift < 1){
        $rshift=1;
    }
    my $t=0;
    my $s=10;
    my $fs=${$sprt}[0];
    my $fn=${$sprt}[1];
    my $dist=$fn - $fs;
    if($dist == 0){
        die "No entries for chromosome!\n";
    }
   
    if($check == 1){
        $cc=2; # column 2 of bedgraph
    }

    while( $dist > $d ){
       my @ps=split(/\t/,line_with_index($file, $index, $fs));
       my @pn=split(/\t/,line_with_index($file, $index, $fn));

       $t=int((($fs + $fn)/2) + 0.5);
       my @pt=split(/\t/,line_with_index($file, $index, $t));
       
       if($rshift > $pt[$cc]){
          $fs=$t;
       }elsif($rshift < $pt[$cc]){
          $fn=$t;
       }
       $d+=1;
       $dist=$fn - $fs;
       my $near=$rshift - $pt[$cc];

       if( $near < 1000 && $near > 0){
          last;
       }
     }
   return($fs);
} 

# maximum number in an array
sub my_max{
    my $max = shift;
    my $next;
    while(@_){
        $next = shift;
        $max = $next if ($next > $max);
    }
    return $max;
}

#minimum number in an array
sub my_min {
    my $min = shift;
    my $next;
    while(@_){
       $next = shift;
       $min = $next if($next < $min);
    }
    return $min;
}

#Mann-Whitney U test
sub mann_whit{
  my $a = shift; # allele1 read positions;
  my $b = shift; # allele2 read positions;
  my $R = Statistics::R->new();
  
  $R->set('a', [@{$a}]);
  $R->set('b', [@{$b}]);
  $R->run(q`c <- wilcox.test(a,b,exact=F,correct=F)`);
  my $p_value = $R->get('c$p.value');

  $R->stop();

  return($p_value);
}

#binomial test
sub binomial{
   my $x=shift; # reference allele count
   my $n=shift; # total minus errors
   my $p=shift; # observe or expected frequency in genomic DNA
   
   my $R = Statistics::R->new();

   $R->set('x', $x);
   $R->set('n', $n);
   $R->set('p', $p);
   $R->run(q`b <- binom.test(x, n, p )`);
   my $p_value = $R->get('b$p.value');
   
   $R->stop();

   return($p_value);
}

#Fisher's exact test
sub fisher{
    my $a = shift;  
    my $b = shift; 
    my $c = shift;
    my $d = shift;

    my $R = Statistics::R->new();
    
    $R->set('a', [$a, $b, $c, $d]);
    $R->run(q`m <- matrix(a,ncol=2)`,
            q`f <- fisher.test(m)`
           );
    my $p_value = $R->get('f$p.value');
    
    $R->stop();
   
    return($p_value);  
}    

#Chi-squared test
sub chisq{
    my $a = shift;
    my $b = shift;
    my $c = shift;
    my $d = shift;
    
    my $R = Statistics::R->new();
    
    $R->set('a', [$a, $b, $c, $d]);
    $R->run(q`m <- matrix(a,ncol=2)`,
            q`c <- chisq.test(m,correct=F)`
            );
    my $p_value = $R->get('c$p.value');
  
    $R->stop();
 
    return($p_value);
}

# extract the read depth surrounding SNV
sub get_dist_for_fig{
    my $alignFile=shift; # Name of .align output file
    my $snp=shift; # SNV Identifier
    my @h1pos=(); 
    my @h1neg=();
    my @h2pos=();
    my @h2neg=();
    my $A1;
    my $A2;
    my $bp;
    my @pos=();
    my $n=0; 
    my $n2=0;
    my $sp=0;
    my $ref;
    my $test="0x0010"; # test negative strand

    my $align;
    open($align,"<",$alignFile) or die "Could not open $alignFile\n";

    while(<$align>){
       chomp();
       my @line=split(/ /);
       if(@line){
          if($line[0] eq $snp){
             $n=1;
             next;
          }
       }
       if($n==1){
          if( @line ){
             if($line[0] eq "Observed"){
                $ref=$line[$#line];
                if($ref eq $line[3]){
                   $A1=$line[3];
                   $A2=$line[5];
                }else{
                   $A1=$line[5]; 
                   $A2=$line[3];
                } 
             }
             
             if($line[0] =~ /@/){
                $n2+=1;
                $sp=$line[1] + $line[2];
                @pos=split(//,$line[0]);
                if($n2 == 1){
                   for(my $j=1; $j <= $#pos; $j++){
                      push(@h1pos, 0);
                      push(@h1neg, 0);
                      push(@h2pos, 0);
                      push(@h2neg, 0);
                   }
          
                }
                my $hex = sprintf("0x%04x",$line[6]);
                if($line[4] eq $A1){
                   if(($hex & $test) ne $test){
                      for(my $i=1; $i <= $#pos; $i++){
                         if($pos[$i] ne "-"){
                            $h1pos[$i] += 1;
                         }
                      }
                   }elsif(($hex & $test) eq $test){
                      for(my $i=1; $i <= $#pos; $i++){
                         if($pos[$i] ne "-"){
                            $h1neg[$i] += 1;
                         }
                      }
                   }
                           
                }
                if($line[4] eq $A2){
                   if(($hex & $test) ne $test){
                      for(my $i=1; $i <= $#pos; $i++){
                         if($pos[$i] ne "-"){
                            $h2pos[$i] += 1;
                         }
                      }
                   }elsif(($hex & $test) eq $test){
                      for(my $i=1; $i <= $#pos; $i++){
                         if($pos[$i] ne "-"){
                            $h2neg[$i] += 1;
                         } 
                      }
                   }
             
                }
           }elsif($line[0] =~ /rs/){
              last;
           }
        }
     }

   }
   close($align);
   return(\@h1pos,\@h1neg,\@h2pos,\@h2neg,$sp);
}

# make a figure of read distribution around a SNP
sub make_figure{
    my $a = shift; # Reference Allele Positive Strand Reads
    my $b = shift; # Reference Allele Negative Strand Reads
    my $c = shift; # Variant Allele Positive Strand Reads
    my $d = shift; # Variant Allele Negative Strand Reads
    my $e = shift; # Position of SNV in alignment  
    my $f = shift; # SNV ID
    my $g = shift; # File ID 

    my $R = Statistics::R->new();

    my $output = "$f.$g.pdf";

    $R->set('a', [@{$a}]);
    $R->set('b', [@{$b}]);
    $R->set('c', [@{$c}]);
    $R->set('d', [@{$d}]);
    $R->set('e', $e);

    $R->run(q`ab <- a + b`,
            q`cd <- c + d`,
            q`m1 <- max(ab)`,
            q`m2 <- max(cd)`,
            q`m <- e + 1`);

    $R->run(qq`pdf("$output", width=8 , height=8)`,
            q`par(mar=c(6.1,6.1,4.1,2.1))`,
            q`plot(ab, type = "l", col="red", lwd=8, ylim=c(-m2 - 20,m1 + 20), ann=F, axes=F)`,
            q`axis(1,at=c(0,m,length(ab)),labels=c(-m,0,+m),cex.axis=1.5,lwd=2)`,
            q`axis(2,at=c(seq(round((-m2 - 10)/20,0)*20,0,by=20), seq(0,round((m1 + 10)/20,0)*20, by=20)),labels=c(seq(round((m2 + 10)/20,0)*20,0, by=-20), seq(0,round((m1 + 10)/20,0)*20, by=20)),las=1,cex.axis=1.5, lwd=2)`, 
            q`points(a, type = "l", col="grey",lwd=4)`,
            q`points(b, type = "l", lty=2, col="grey", lwd=4)`,
            q`points(-1 * cd, type = "l", col="blue", lwd=8)`,
            q`points(-1 * c, type = "l", col="grey", lwd=4)`,
            q`points(-1 * d, type = "l", lty=2, col="grey", lwd=4)`,
            q`title(ylab="Depth of Sequence Reads Containing SNP (n)",xlab="Position Relative to SNP",cex.lab=1.5)`,
            q`text(e,m1 + 20,"Reference Allele",col="red",cex=2)`,
            q`text(e,-m2 - 20,"Alternate Allele",col="blue",cex=2)`,
            q`abline(h=0,lty=2,col="black",lwd=3)`,
            q`dev.off()`);

    $R->stop();

}



#print comma delimited
sub print_comma_delim{
   my $a=shift;
   my $b=shift;
   my $c=shift;

   if(defined ${$a}[0]){
      for(my $i=0; $i<=$#{$a}; $i++){
         if($i != $#{$a}){
             print $b "${$a}[$i],";
         }else{
             if($c==1){
                print $b "${$a}[$i]\t";
             }else{
                print $b "${$a}[$i]\n";
             }
         }
      }
   }else{
      if($c==1){
         print $b "NA\t";
      }else{
         print $b "NA\n";
      }
   }
}

#print aligned reads 
sub print_aligned_reads{
    my $Allele_ref=shift;
    my $refAllele=shift;
    my $output=shift;
    my $Starts_ref=shift;
    my $Reads_ref=shift;
    my $Stops_ref=shift;          
    my $Rpos_ref=shift;
    my $strand_ref=shift;
    my $max=shift;
    my $min=shift;
    my $bp=shift;
 
    my $pos = $bp - $min + 1;
    for(my $i=1; $i <= $pos + 1; $i++){
       if($i != $pos + 1){
           print $output " ";
       }else{
           print $output "*\n";
       }
    }

    for(my $i=0; $i <= $#{$Reads_ref}; $i++){
        if(${$Allele_ref}[$i] eq $refAllele){
            print $output "@";
            my $lpad=${$Starts_ref}[$i] - $min;
            for(my $j=1; $j <= $lpad; $j++){
               print $output "-";
            } 
            print $output "${$Reads_ref}[$i]";
            my $upad= $max - ${$Stops_ref}[$i];
            for(my $j=1; $j <= $upad; $j++){
               print $output "-";
            }
            print $output " $lpad $upad --- ${$Allele_ref}[$i] ${$Rpos_ref}[$i] ${$strand_ref}[$i]\n";
        }
    }
    print $output "\n";
}

sub check_tab_delim{
   my $a=shift;

   if($#{$a} == 0){
      print "Input is not tab delimited!\n";
      die;
   }
}
 
# get a line from file using the index
sub line_with_index{
   my $dataFile = shift;
   my $indexFile = shift;
   my $lineNumber = shift;

   my $size;            
   my $i_offset;          
   my $entry;             
   my $d_offset;           

   $size = length(pack("Q>", 0));
   $i_offset = $size * ($lineNumber-1);
  
   seek($indexFile, $i_offset, 0) or return;
   read($indexFile, $entry, $size);

   $d_offset = unpack("Q>", $entry);
   
   seek($dataFile, $d_offset, 0);
 
   return scalar(<$dataFile>);
}

#create mask for portion of a read
sub mask{
   my $start=shift;
   my $end=shift;
   my @read=();
 
   for(my $j=$start; $j<=$end; $j++){
     push(@read, "-");
   }
  
   return(@read);
}


# command line wrapper
sub getCommands{
    my $argv_ref=shift;
    my $minr=25;
    my $d=2000;
    my $samfile;
    my $snpfile;
    my $outdist="ABC.dist";
    my $outalign="ABC.align";
    my $outtemp="ABC";
    my $bgfile;
    my $vsnv;
    my $sam=0;
    my $vis=0;
    my $verb=0;
    my $snp=0;
    my $mwt=0.05;
    my $ft=0.05;
    my $map=0;

    if(@{$argv_ref}){ 
       for(my $x=0; $x <= $#{$argv_ref}; $x++){
          if(${$argv_ref}[$x] eq "--snv-file"){
             $snp=1;
             $snpfile=${$argv_ref}[$x + 1];
          }
          if(${$argv_ref}[$x] eq "--align-file"){
             $sam=1;
             $samfile=${$argv_ref}[$x + 1];
          }
          if(${$argv_ref}[$x] eq "--bg"){
             $bgfile=${$argv_ref}[$x + 1];
          }
          if(${$argv_ref}[$x] eq "--out"){
             $outdist=${$argv_ref}[$x + 1] . '.dist';
             $outalign=${$argv_ref}[$x + 1] . '.align';
             $outtemp=${$argv_ref}[$x + 1];
          }
          if(${$argv_ref}[$x] eq "--min-reads"){
             $minr=${$argv_ref}[$x + 1];
          }
          if(${$argv_ref}[$x] eq "--d"){
             $d=${$argv_ref}[$x + 1];
          }
          if(${$argv_ref}[$x] eq "--help"){
              print "\n\nUsage: perl ABC.pl --align-file <input.sam> --snv-file <snv filename> --out <output filename prefix>\n\n";
              print "\n--align-file (Required)\n\t\tSpecify ChIP-Seq alignment file BAM/SAM.\n\t\tNote: the BAM/SAM file must be sorted\n";
              print "\n--bg (Optional)\n\t\tSpecify a .bedgraph file capturing the ChIP-Seq signal (shifted read pileups) of the .sam file\n";
              print "\t\tThis can be useful to prioritize SNPs with low coverage, since they may fall within the centre of the +ve and -ve\n";
              print "\t\tstrand peaks of the ChIP-Seq reads. This is caused by short read lengths and is not necessary for longer reads.\n";
              print "\n--snp-file (Required)\n\t\tA text file containing the list of heterozygous SNPs (SEE README.txt for format).\n";
              print "\n--out (Optional)\n\t\tSpecify the ouput file prefix (default ABC).\n";
              print "\n\t\t(ie. ABC will create two output files ABC.dist and ABC.align)\n";
              print "\n--min-reads (Optional)\n\t\tThe minimum number of reads covering a SNP (default: 25).\n";
              print "\n--d (Optional)\n\t\tDivide chromosomes into segments until reaching d lines for faster retrieval (default: 2000).";
              print "\n\t\tNote: Very large numbers will not necessarily increase speed.\n\n";
              print "\n--mw-thres (Optional)\n\t\tP-value threshold for the Mann-Whitney test used to test a bias in the read position between the SNV alleles. (default: 0.05)\n";
              print "\t\tTo report all SNVs set this parameter to 0.\n";
              print "\n--f-thres (Optional).\n\t\tP-value threshold for the Fisher's exact test used to test for a bias between the strand distribution of the SNV alleles. (default: 0.05)\n";
              print "\t\tTo report all SNVs set this parameter to 0.\n";
              print "\n--min-mapq (Optional).\n\t\tSet the minimum allowed MAPQ score (default: 0).\n";
              print "\n--verbose (Optional).\n\t\tPrint progress and SNV results summary to screen.\n\n";
              print "\n\t\t\t***\tVISUALIZING SNV RESULTS\t***\n\n\t\tCreate a figure of the distribution of reads containing a SNV of interest\n";
              print "\n\t\tThis step requires that the ABC has finished running.\n\t\tOnce ABC is finished a figure can be generated by specifying the output file prefix ";
              print "used in the initial run and the SNV ID as follows:"; 
              print "\n\n\t\tperl ABC.pl --out <output filename prefix> --visualize-snv <SNV ID>\n\n";
              exit;
          }
          if(${$argv_ref}[$x] eq "--mw-thres"){
              $mwt=${$argv_ref}[$x + 1];
          }
          if(${$argv_ref}[$x] eq "--f-thres"){
              $ft=${$argv_ref}[$x + 1];
          }  
          if(${$argv_ref}[$x] eq "--visualize-snv"){
              $vsnv=${$argv_ref}[$x + 1];
              $vis=1;
          }
          if(${$argv_ref}[$x] eq "--verbose"){
              $verb=1;
          }
          if(${$argv_ref}[$x] eq "--min-mapq"){
              $map=${$argv_ref}[$x + 1];
          } 
       }
       if($vis == 0){
          if($sam == 0 || $snp == 0 ){
             print "\n\nUsage: perl ABC.pl --align-file <input.sam> --snv-file <snv filename> --out <output filename>\n";
             print "Required input files are missing!\n\n";
             exit;
          }
       }
    }else{
         print "\n\nUsage: perl ABC.pl --align-file <input.sam> --snv-file <snv filename> --out <output filename>\n";
         print "For command line options type:\tABC --help\n\n";
         exit;
    } 

return($snpfile, $samfile, $bgfile, $outdist, $outalign, $minr, $d, $mwt, $ft, $verb, $vsnv, $map, $outtemp);
}

# ABC Program
my $SNPfile;
my $inputSam;
my $inputBg;
my $align;
my $ASdist;
my $indexBg;
my $indexbgFile;
my $bg=0;

# Complement for flipping strands
my %Compl = (
        A => "T",
        C => "G",
        G => "C",
        T => "A"
   );

(my $SNPfilename, my $inputSamFile, my $inputBgFile, my $ASdistribution, my $alignments, my $minR, my $d, my $mwt, my $ft, my $verb, my $vsnv, my $map, my $outpref)=getCommands(\@ARGV);

# If visualization is specified make a SNP figure and quit 
if(defined $vsnv && defined $alignments){
   (my $h1pos_ref, my $h1neg_ref, my $h2pos_ref, my $h2neg_ref, my $sp)=get_dist_for_fig($alignments, $vsnv);
   if(@{$h1pos_ref}){
       make_figure(\@{$h1pos_ref},\@{$h1neg_ref},\@{$h2pos_ref},\@{$h2neg_ref}, $sp, $vsnv, $alignments);
       print "\nYour figure $vsnv.$alignments.pdf is finished.\n\n";
   }else{
       print "\n$vsnv was not found in $alignments!\n\n";
   }
   exit;
}

open($SNPfile,"<", $SNPfilename) or die "Could not open $SNPfilename!\n";

my $b=0;
my $tbam;
my $tbamname;
my $template="ABC_TEMP_XXXXXXX";
my $tempname=join("_",$outpref,$template);    

if($inputSamFile =~ /.bam$/){ 
   open($inputSam,"samtools view $inputSamFile |") or die "Could not open $inputSamFile!\n";

   print "Extracting Alignments from $inputSamFile\n";
 
   ($tbam, $tbamname) = tempfile( $tempname, UNLINK => 1, SUFFIX => ".sam");
   open($tbam,"+>",$tbamname) or die "Could not open $tbamname for read/write!\n";
   while(<$inputSam>){
      print $tbam "$_";
   }
   $b=1;
   close($inputSam);
   $inputSam=$tbam;
 
}else{
   open($inputSam,"<",$inputSamFile) or die "Could not open $inputSamFile!\n";
}

(my $indexSam, my $indexSamFile) = tempfile( $tempname, UNLINK => 1, SUFFIX => ".idx");
open($indexSam, "+>", $indexSamFile) or die "Could not open $inputSamFile for read/write!\n";

if(!defined($ASdistribution)){
   $ASdistribution="ABC.dist";
   $alignments="ABC.align";
}

open($ASdist,">",$ASdistribution) or die "Could not open $ASdistribution!\n";
open($align,">",$alignments) or die "Could not open $alignments\n";

# Create index of .sam file
print "\nBuilding index of $inputSamFile\n";

my $chroms_ref;
my $positions_ref;
my $sam_n;
my $read_length;

($chroms_ref, $positions_ref, $sam_n, $read_length)=build_index($inputSam, $indexSam, 0, $b);
my @chroms=@$chroms_ref;
my @positions=@$positions_ref;

(my $chrIn_ref_2)=get_file_landmarks_2(\@chroms, \@positions, $sam_n);
my %chrIn_2=%$chrIn_ref_2;

print "Finished!\n\n";

# If extract MAX from .bedgraph is specified
# Variables for .bedgraph file (if defined).
my @bg_chroms=();
my @bg_positions=();
my %bg_chrIn_2=();
my $bg_max;
my $bg_n=0;

if(defined($inputBgFile)){
    
    $bg=1;
    open($inputBg,"<",$inputBgFile) or die "Could not open $inputBgFile!\n";
    ($indexBg, $indexbgFile) = tempfile( $tempname, UNLINK => 1, SUFFIX => ".bg.idx");
    open($indexBg, "+>", $indexbgFile) or die "Could not open $indexbgFile for read/write!\n";

    # Create index of .bedgraph file
    print "Building index of $inputBgFile\n";

    (my $bg_chroms_ref,my $bg_positions_ref, $bg_n)=build_index($inputBg, $indexBg, 1, 0);
    @bg_chroms=@$bg_chroms_ref;
    @bg_positions=@$bg_positions_ref;
 
    print "Finished!\n";
}

# Print output file header
print $ASdist "SNV\tCHR\tBP\tREF\tOBS\tA1\tN_A1\tF_A1\tN_A1_POS\tN_A1_NEG\tA2\tN_A2\tF_A2\tN_A2_POS\tN_A2_NEG\tN_TOTAL\tN_ERRORS\tN_OMITTED\tMISSING_N\t";
print $ASdist "MAX\tBINOM\tP_MANN_WHIT\tP_FISHER\tP_CHISQ\tP_STRAND\tA1_Position\tA1_Strand\tA2_Position\tA2_strand\n";


# Begin reading SNP file
while(<$SNPfile>){
   chomp();
   my @Reads=();
   my @Starts=();
   my @Stops=();
   my @Rpos=();
   my @Allele=();
   my @strand=();
   my $n=0;
   my @line1=split(/\t/);
   check_tab_delim(\@line1);
 
   my $chr=$line1[1]; 
   my $bp=$line1[2];
   my $rs=$line1[0];
   my $ref=$line1[4];
   my @refA=split(/\//,$line1[5]);
   my $ps=$line1[6];

   # check input
   if(!looks_like_number($bp) || !looks_like_number($ps)){
      die;
   }elsif(looks_like_number($ref) || looks_like_number($refA[0]) || looks_like_number($refA[1])){ # || looks_like_number($chr)){ #if they used b37 this is a problem
      die;
   } 


   if(($#refA > 1) || ($#refA < 1)){ #skip mono or multiple (>2) alleles
      next;
   }elsif($#refA == 1){
      if(($refA[0] eq "-") || ($refA[1] eq "-")){ #skip deletions
         next;
      }elsif((length($refA[0]) > 1) || (length($refA[1]) > 1)){ #skip insertions
         next;
      }
   }

   if((length($ref) > 1)){ # Skip Insertions
       next;
   }
      
   my $strand=$line1[3];
   if($strand eq "-"){
       $refA[0]=$Compl{$refA[0]};
       $refA[1]=$Compl{$refA[1]};
   }

   my $refAllele;
   my $nonrefAllele;
   if(($refA[0] ne $ref) && ($refA[1] ne $ref)){ #skip problem with strand
       print "PROBLEM - Possible strand issue: $rs\n";
       next;
   }else{
      if($refA[0] eq $ref){
         $refAllele=$refA[0];
         $nonrefAllele=$refA[1];
      }else{
         $refAllele=$refA[1];
         $nonrefAllele=$refA[0];
      }
   }

   my $snpstart = $bp - $read_length - 1; # lower window boundary around SNP
   my $snpend = $bp + $read_length + 1 ;  # upper window boundary around SNP

   # Find file position to begin search in .sam file 
   my $s=${$chrIn_2{$chr}}[0];

   $s=find_starting_point(\@{$chrIn_2{$chr}},$chr, $bp, $read_length, $inputSam, $indexSam, 0, $d);
 
   for(my $i=$s; $i <= ${$chrIn_2{$chr}}[1]; $i++){

      my @line2=split(/\t/,line_with_index($inputSam, $indexSam, $i));
      my @Chrom=split(/(\d+)/, $line2[2]);
      my $chrom=$line2[2];
      my $start=$line2[3];
      my $mapq=$line2[4];
      my @splitread=split(//,$line2[9]);
      my $strand=$line2[1];
      my $cigar=$line2[5]; 
      my $len=length($line2[9]);
      my @lcig = $cigar =~ /\d+/g;     
      my @tcig = $cigar =~ /\D+/g;     
      my $scig = 0;
      my @mask=();  
      my @nread=();
      my @readslice=();

      if($tcig[0] ne "*"){
         for(my $i=0; $i<=$#tcig; $i++){
            my @tmp=@splitread;
            if($tcig[$i] ne "H" && $tcig[$i] ne "D" && $tcig[$i] ne "N" && $tcig[$i] ne "P"){
               $scig+=$lcig[$i];
            }            
            if($tcig[$i] eq "M" || $tcig[$i] eq "=" || $tcig[$i] eq "X"){
               if($i==0){
                  @readslice=splice(@tmp, 0, $lcig[$i]);
                  push(@nread,@readslice);
               }elsif($i==$#tcig){
                  @readslice=splice(@tmp,$scig - $lcig[$i], $lcig[$i]);
                  push(@nread,@readslice);
               }else{
                  @readslice=splice(@tmp,$scig - $lcig[$i], $lcig[$i]);
                  push(@nread,@readslice); 
               }
            }
            if($tcig[$i] eq "D" || $tcig[$i] eq "S" || $tcig[$i] eq "N" || $tcig[$i] eq "P" ){
               if($i != 0){
                 @mask=mask(1,$lcig[$i]);
                 push(@nread,@mask);
               }else{
                 next;
               }
            }
        } 
      }

      my $read=join("",@nread);
      my $end=$start + length($read) - 1;

      # check --- in case issue with index
      #if(looks_like_number($chr) || looks_like_number($read)){ # if b37 $chr is a number.
      if(looks_like_number($read)){
          die;
      }elsif(!looks_like_number($start)){
          die;
      }
      
   
      if($chr eq $chrom){
         if($start > $bp){
              last;
         }
         if(($bp >= $start) && ($bp <= $end)){
           if($mapq >= $map){
              $n+=1;

              my $dist = $bp - $start + 1;
              my $all = substr($read, $dist - 1, 1);
            
              push( @Reads, $read );
              push( @Starts, $start );
              push( @Stops, $end );
              push( @Rpos, $dist );
              push( @Allele, $all );
              push( @strand, $strand);
           }else{
              next;
           }
         }
      }else{
        next;
      }
   }

   my $A1=0;
   my $A2=0;

   if($n >= $minR){
      
       # if .bedgraph is specified
       if($bg==1){
          # Find file position to begin search .bedgraph file 
          (my $bg_chrIn_ref_2)=get_file_landmarks_2(\@bg_chroms, \@bg_positions, $bg_n );#, $inputBg, $indexBg);
          %bg_chrIn_2=%$bg_chrIn_ref_2;
          my $s_2=${$bg_chrIn_2{$chr}}[0];

          $s_2=find_starting_point(\@{$bg_chrIn_2{$chr}},$chr, $bp, $read_length, $inputBg, $indexBg, 1, $d);
          my @region=();
         
          for(my $i=$s_2; $i <= ${$bg_chrIn_2{$chr}}[1]; $i++){
   
              my @line3=split(/\t/,line_with_index($inputBg, $indexBg, $i));
              chomp(@line3);
   
              my $s_step=$line3[1];
              my $e_step=$line3[2];
              my $count=$line3[3];
            
              # check 
              if(!looks_like_number($s_step) || !looks_like_number($e_step) || !looks_like_number($count)){
                  die;
              }  
             
              if($e_step < $snpstart){
                 next;
              }elsif($s_step > $snpend){
                 last;
              }else{
                 if($s_step <= $snpend && $e_step >= $snpstart){
                     push(@region, $count);
                 }
             }
           }

           if(defined($region[0])){
               $bg_max=my_max(@region);
           }else{
               $bg_max="NA";
           }

       }else{
          
           $bg_max="NA";
    
       }
   
       my $max = my_max(@Stops);
       my $min = my_min(@Starts);
       my $omit=0;
       my $amb=0;

       for(my $i=0; $i <= $#Reads; $i++){
          if($refAllele eq $Allele[$i]){
              $A1+=1;
          }elsif($nonrefAllele eq $Allele[$i]){
              $A2+=1;
          }elsif($Allele[$i] eq "-"){
              $omit+=1;
          }elsif($Allele[$i] eq "N"){
              $amb+=1;
          }
       }
   
       # Determine an allele-specific bias exist
 
       my $total=$A1 + $A2;
       my $bpval=1;

       if($total < 1){
             print "PROBLEM - Check Alleles of SNP: $rs\n";
          }else{
         
             $bpval=binomial($A1, $total, $ps); 
             my $pout=0; 
             my $qout=0;
             my $errN=0;
 
             if($A1 != 0){ 
                $pout=sprintf("%0.2f", $A1/($A1 + $A2));
                $qout=sprintf("%0.2f", 1-$pout);
             }else{
                $pout=sprintf("%0.2f", 0);
                $qout=sprintf("%0.2f", 1);
             }
     
             my $A1pos=0; # number of reference alleles +ve strand
             my $A1neg=0; # number of reference alleles -ve strand
             my $A2pos=0; # number of alternate alleles +ve strand
             my $A2neg=0; # number of alternate alleles -ve strand
             my @A1=();
             my @A2=();
             my @A1strand=(); 
             my @A2strand=();
             my $test="0x0010"; # test negative strand
             my $hex;

             for(my $i=0; $i <= $#Rpos; $i++){
                if($Allele[$i] eq $refAllele){
        
                    $hex = sprintf("0x%04x",$strand[$i]);
                    push(@A1,$Rpos[$i]);
        
                    if(($hex & $test) ne $test){ 
                        $A1pos+=1;
                        push(@A1strand,"+");
                    }else{
                        $A1neg+=1;
                        push(@A1strand,"-");
                    }
             
                }elsif($Allele[$i] eq $nonrefAllele){
       
                    $hex = sprintf("0x%04x",$strand[$i]);
                    push(@A2,$Rpos[$i]);
           
                    if(($hex & $test) ne $test){
                       $A2pos+=1;
                       push(@A2strand,"+");
                    }else{
                       $A2neg+=1;
                       push(@A2strand,"-");
                    }
                }
            }

            my $total_pos=$A1pos + $A2pos;
            my $total_neg=$A1neg + $A2neg;   
 
            my $pstrand;
            my $tp;
     
            #check for unequal distribution of +ve and -ve strand reads
            #A negative (or weak) result helps indicate if SNP is in the centre.  

            $pstrand=binomial($total_pos,$total,0.5);

            #check for equal distribution of positive and negative for both alleles
            #indicates a shift in the positive and negative reads for each allele 
            #likely false positive if the allele-specific binomial probability is significant
   
            my $fish=fisher($A1pos, $A1neg, $A2pos, $A2neg);
            my $chisq;

            #check expected values >= 5

            if((($A1pos + $A2pos) * ($A1pos + $A1neg))/$total >= 5 && (($A1pos + $A2pos) * ($A2pos + $A2neg))/$total >= 5 && (($A1neg + $A2neg) * ($A1pos + $A1neg))/$total >= 5 && (($A1neg + $A2neg) * ($A2pos + $A2neg))/$total >= 5){
                 $chisq=chisq($A1pos, $A1neg, $A2pos, $A2neg);
            }else{
                 $chisq="NA";
            }

            # Check for a bias of the allele position in reads
            if(@A1 && @A2){    
                 $tp=mann_whit(\@A1,\@A2);
            }else{
                 $tp="NA";
            }  
     
            if($total + $omit != $n){
                 $errN = $n - $total - $omit - $amb;
            }
     
            if(($tp eq "NA") || ($tp >= $mwt) && ($fish >= $ft)){
                #Print Results and summary for SNP
                if($verb == 1){ 
                    print "\n$rs $chr $bp -- The frequency of the $refAllele ($A1) allele = $pout and the $nonrefAllele ($A2) allele = $qout\n";
                    print "Observed Alleles = $refA[0] / $refA[1] --- Reference Allele = $ref\n";
                    print "\n$rs -- Number of unexpected alleles = $errN \n";
                    print "$rs -- Number of omitted alleles = $omit \n";
                    print "A1 strand (+ve,-ve) = $A1pos, $A1neg // A2 strand (+ve,-ve)  =  $A2pos, $A2neg\n"; 
                    print "ASB_BINOM = $bpval\n";
                    print "MANN_WHIT = $tp\n"; 
                    print "STRAND_BINOM = $pstrand\n";
                    print "FISHER = $fish\n"; 
                    print "CHISQ = $chisq\n"; 
                    print "SIG_MAX = $bg_max\n";
                } 

                print $align "$rs $chr $bp -- The frequency of the $refAllele ($A1) allele = $pout and the $nonrefAllele ($A2) allele = $qout\n";
                print $align "Observed Alleles = $refA[0] / $refA[1] --- Reference Allele = $ref\n";
                print $ASdist "$rs\t$chr\t$bp\t$ref\t@refA\t$refAllele\t$A1\t$pout\t$A1pos\t$A1neg\t$nonrefAllele\t$A2\t$qout\t$A2pos\t$A2neg\t$n\t$errN\t$omit\t$amb\t";
                print $ASdist "$bg_max\t$bpval\t$tp\t$fish\t$chisq\t$pstrand\t";

                print_comma_delim(\@A1, $ASdist, 1);
                print_comma_delim(\@A1strand, $ASdist, 1);
                print_comma_delim(\@A2, $ASdist, 1);
                print_comma_delim(\@A2strand, $ASdist, 0);

                print_aligned_reads(\@Allele,$refAllele,$align,\@Starts,\@Reads,\@Stops,\@Rpos,\@strand,$max,$min,$bp);   
                print_aligned_reads(\@Allele,$nonrefAllele,$align,\@Starts,\@Reads,\@Stops,\@Rpos,\@strand,$max,$min,$bp);
           }
       }
   }
}


print "Finished! Check the output files $ASdistribution and $alignments for a summary of the results.\n";

close($inputSam);
close($indexSam);
close($SNPfile);
close($ASdist);
close($align);
if($b==1){
  close($tbam);
}
if(defined ($inputBgFile)){
   close($inputBg);
   close($indexBg);
}
