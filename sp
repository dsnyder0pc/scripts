#!/usr/bin/env perl
################################################################################
#
#  sp
#
#  This program works somewhat like du(1) in that it reports on the
#  space used by files and directories.  Unlike du(1), it only includes
#  directories that contain at least one file or directory which has
#  used a specified amount of space (default is 1 MB) in the report. 
#  Also, it does not cross filesystem boundaries.
#
#  The intent of sp is to produce a report that can be used by a human
#  to quickly isolate files and directories that can be removed to
#  reclaim space.
#
################################################################################
use Getopt::Std;
use strict;

=head1 NAME

sp - report on disk space usage

=head1 SYNOPSIS

B<sp>  [ B<-hdfHT> ]  [ B<-R> I<rows> [ B<-P> I<prefix> ] ]  [ B<-c> I<cols> ]  [ B<-m> I<size> ]  [ B<-i> I<pattern, ...> ]  [ B<-x> I<pattern, ...> ]  [ directory ... ]

=cut

########################################
#
#  Parse the command line
#
my $usage = "Usage: $0 [-hdfHT] " .
            "[-R rows [-P prefix]] [-c cols] [-m size] " .
            "[-i pattern] [-x pattern] [directory ...]\n";
my %opts;
die $usage unless getopts( '-hdfHTR:P:c:m:i:x:', \%opts );
if ( defined $opts{'h'} ) {
   print "$usage
\t-h : display help
\t-d : cross filesystem boundaries
\t-f : follow symbolic links
\t-H : generate HTML output
\t-T : include <TABLE> tags in HTML output
   -R rows : write HTML files with no more than the specified number of rows
 -P prefix : use the specified prefix for each HTML filename (default is sp)
   -c cols : force output width to the specified number of columns
   -m size : exclude files that are smaller than size KB (default is 1024)
-i pattern : include only paths that match one or more comma separated patterns
-x pattern : exclude paths that match any of the comma separated patterns\n\n";
   exit 0;
}

########################################
#
#  Declarations of file scoped
#  global variables
#
my $min_size = (defined $opts{'m'} ? $opts{'m'} : 1024) * 2; # 512 byte blocks
my ($scale, $units);
if (      $min_size <     1000 ) {   # -m < 500
   ($scale, $units) = (      2, "KB");
} elsif ( $min_size <  1000000 ) {   # -m < 500,000
   ($scale, $units) = (   2048, "MB");
} else {
   ($scale, $units) = (2097152, "GB");
}
my @includes = defined $opts{'i'} ? split /,/, $opts{'i'} : ();
my @excludes = defined $opts{'x'} ? split /,/, $opts{'x'} : ();
my $prefix   = defined $opts{'P'} ? $opts{'P'} : "sp";

my %iv;            # Hash of bit vectors used to track files that we've seen
my %big_files;     # Files larger than $min_size, indexed by device and inode
my $max_len = 15;  # The longest filename of all files larger than $min_size
my $gino = 0;      # Fake inode counter used for WIN32 support

########################################
#
#  The /proc filesystem is funky, so
#  let's avoid it.  We do this by
#  pretending that we've already seen
#  it.  The scan_tree() function doesn't
#  visit inodes that are set in an
#  %iv bit vector.
#
if ( -d "/proc" ) {
   my ($dev, $ino) = lstat "/proc";
   $iv{ $dev } = "";
   vec( $iv{ $dev }, $ino, 1 ) = 1;
}

########################################
#
#  Scan the specified directory and
#  report on all directories that
#  contain files which consume at
#  least $min_size KB.
#
@ARGV = ( "." ) unless ( @ARGV );
foreach my $dir ( @ARGV ) { scan_tree( $dir ) };
undef %iv;  # not needed anymore, so release memory
$max_len = (($opts{'c'} < 34) ? 34 : $opts{'c'}) - 23 if ( defined $opts{'c'} );
my $row_count   = 0;
my $table_count = 0;
foreach my $f_ref ( sort { $b->[0] <=> $a->[0] }
                    grep { ref } values %big_files )
{
   next if ( $#$f_ref < 2 );  # no subdirs associated with this file
   if ( defined $opts{'R'} ) {
      if ( $opts{'R'} < $row_count + $#$f_ref ) {  # Close current file
         $row_count = 0;
         print "</TABLE>\n" if ( defined $opts{'T'} );
      }
      if ( 0 == $row_count ) {  # Open a new file
         my $output_file = sprintf "%s-%04x.htm", $prefix, ++$table_count;
         open HTML, "> $output_file"  or die "$0: open $output_file: $!\n";
         select HTML;
      }
   }
   print_dir( $f_ref->[1], $f_ref->[0] / $scale );
   $row_count += 2;
   foreach my $sub_ino ( sort { $big_files{ $b }[0] <=>
                                $big_files{ $a }[0] } @$f_ref[ 2 .. $#$f_ref ] )
   {
      print_subdir( $big_files{ $sub_ino }[1],
                    $big_files{ $sub_ino }[0] / $scale,
                    $big_files{ $sub_ino }[0] *100 / $f_ref->[0] );
      $row_count++
   }
}
if ( (defined $opts{'H'} or defined $opts{'R'}) and defined $opts{'T'} ) {
   print "</TABLE>\n";
}

exit 0;


########################################
#
#  scan_tree
#
#  This recursive function takes a
#  filename and, in a scalar context,
#  returns the number of blocks
#  allocated to that file, including
#  subdirectories.  In a list context,
#  it also returns the device number
#  and inode number of the file,
#  delimited by a colon.
#
#  If the specified file has already
#  been seen, or if it can not be
#  accessed via lstat()/stat(),
#  scan_tree returns undef.
#
#  As a side-effect, it populates the
#  %big_files hash with references to
#  files and directories that are larger
#  than $min_size.  The structure of the
#  %big_files hash looks like this:
#
#            %big_files
#                |
#   {device number : inode number}
#                |
#                v
#       +--------+--------+--  ...
#       |        |        |
#      [0]      [1]      [2]   ...
#       |        |        |
#       v        v        v
#     size     name     subdir ...
#                       inode
#
sub scan_tree {
   my $top_file = shift;
   my ($dev, $ino, $size, $blocks) =
      defined $opts{'f'} ? ( stat  $top_file )[0, 1, 7, 12] 
                         : (lstat $top_file )[0, 1, 7, 12];
   return undef unless ( defined $dev );  # lstat()/stat() failed
   return undef if ( -b _ or -c _ );      # These guys don't have real sizes
   my $top_dev = (shift or $dev);
   $ino = ++$gino unless ( $ino );        # WIN32 doesn't use inodes, so fake it
   my $sum = 0;
   $iv{ $dev } = "" unless ( exists $iv{ $dev } );  # initialize bit vector

   if ( ($top_dev != $dev and         # Skip file if different filesystem
         not defined $opts{'d'}) or   #    unless user specified -d
        vec($iv{ $dev }, $ino, 1) or  # Count hard links and dirs only once
        defined $big_files{ "$dev:$ino" } )
   {
      return undef;
   } else {
      my @big_subs;  # List of files below $top_file that are > $min_size
      local *DIR;    # Must localize this because we are recursive
      $sum = ($blocks or int( ($size+1023)/1024 )*2);  # Guess blocks for Linux
      if ( -d _ and opendir DIR, $top_file ) {
         my ($file, $size, $sub_ino);
         my $dlm = ($top_file eq "/") ? "" : "/";  # Avoid duplicate /'s
         while ( defined ($file = readdir DIR) ) {
            next if ( $file eq "." or $file eq ".." );
            undef $size;
            if ( path_check( $top_file . $dlm . $file ) ) {
               ($size, $sub_ino) = scan_tree( $top_file . $dlm . $file,
                                              $top_dev );
            }
            if ( defined $size ) {
               $sum += $size;
               push @big_subs, $sub_ino if ( $min_size < $size );
            }
         }
         closedir DIR;
      } elsif ( 0 < $ino and $ino < 8388608 ) {  # use bit vector to
         vec( $iv{ $dev }, $ino, 1 ) = 1;        # track small inodes
      } else {                      # use hash to track large inodes
         $big_files{ "$dev:$ino" } = 1;
      }
      if ( $min_size < $sum ) {  # Save info about big files for the report
         $big_files{ "$dev:$ino" } = [ $sum, $top_file ];
         push @{$big_files{ "$dev:$ino" }}, @big_subs if ( @big_subs );
         $max_len = length $top_file if ( $max_len < length $top_file );
      }
   }

   return wantarray ? ( $sum, "$dev:$ino" ) : $sum;
}


########################################
#
#  patch_check
#
#  Given a filename, this function
#  returns 1 if the filename should
#  be included from the report, and
#  zero otherwise.
#
sub path_check {
   my $file  = shift;
   my $name_ok = 1;

   if ( @includes ) {
      $name_ok = 0;
      foreach my $pat ( @includes ) {
         if ( $file =~ /$pat/ ) {
            $name_ok = 1;
            last;
         }
      }
   }
   foreach my $pat ( @excludes ) {
      if ( $file =~ /$pat/ ) {
         $name_ok = 0;
         last;
      }
   }

   $name_ok;
}


########################################
#
#  print_dir
#
#  This routine prints a header and
#  the name and total space used
#  by a directory and all of its
#  subdirectories and files in either
#  text or HTML format.
#
sub print_dir {
   my $name = shift;
   my $size = shift;

   if ( defined $opts{'H'} or defined $opts{'R'} ) {
      if ( $row_count ) {
         print
            "<TR>\n",
            "   <TD COLSPAN=4><BR></TD>\n",
            "</TR>\n";
      } elsif ( defined $opts{'T'} ) {  # First line of file or stdout
         print
            "<TABLE>\n" if ( defined $opts{'T'} );
      }
      print "<TR>\n",
            "   <TH ALIGN=left COLSPAN=2>Directory Name</TH>\n",
            "   <TH ALIGN=right>Size ($units)</TH>\n",
            "   <TD><BR></TD>\n",
            "</TR>\n",
            "<TR>\n",
            "   <TD ALIGN=left COLSPAN=2>", $name, "</TD>\n", sprintf(
            "   <TD ALIGN=right>%.1f</TD>\n", $size ),
            "   <TD><BR></TD>\n",
            "</TR>\n";
   } else {
      print "\n" if ( $row_count );
      printf "%-" . ($max_len+3) . "s %9s\n",
         "Directory Name", "Size ($units)";
      printf   "%-" . ($max_len+3) . "s %9.1f\n",
         ($max_len+3 < length $name) ? substr( $name, 0, $max_len+2 ) . ">"
                                     : $name,
         $size;
   }
}


########################################
#
#  print_subdir
#
#  This routine prints information
#  about a particular subdirectory
#  or file in either text or HTML
#  format.
#
sub print_subdir {
   my $name = shift;
   my $size = shift;
   my $pct  = shift;

   if ( defined $opts{'H'} or defined $opts{'R'} ) {
      print "<TR>\n",
            "   <TD width=15><BR></TD>\n",
            "   <TD ALIGN=left>", $name, "</TD>\n", sprintf(
            "   <TD ALIGN=right>%.1f</TD>\n", $size ), sprintf(
            "   <TD ALIGN=right>%.1f%%</TD>\n", $pct ),
            "</TR>\n";
   } else {
      printf "   %-" . ($max_len) . "s %9.1f  [%5.1f%%]\n",
         ($max_len < length $name) ? "<" . substr( $name, -($max_len-1) )
                                   : $name,
         $size,
         $pct;
   }
}


__END__

=head1 DESCRIPTION

The B<sp> command scans the current working directory, or one or more
directories specified on the command line, and produces a disk space usage
report.  The directories in the report are sorted in decreasing order
by the amount of disk space used.  The report can be formatted as either
text or HTML.

The intent of B<sp> is much like that of B<du>, to summarize disk
usage for a collection of subdirectories.  However, for a large
directory structure, the full output of B<du> can be megabytes or
more.  The author frequently found himself running a series of
C<S<du -sk * | sort -n>> commands by hand in various top level
directories to get a sense of which subdirectories or files were
consuming most of the space.

This is a time and resource intensive manual process that often
presents an incomplete picture of the disk space usage.  For it's
intended use, locating significant disk usage, B<sp> is better than
B<S<du | sort>> because it collects the information in a single pass,
and it reduces the quantity of output by leaving out files and
directories do not consume significant disk space.  You may specify
what you consider to be I<significant> via the C<-m> switch; however,
be aware that values much smaller than 1024 can cause the virtual
memory used by B<sp> to jump into the 100's of MB for a very large
directory tree.

=head2 OPTIONS

=over 4

=item C<-h>

Display a brief summary of the command line options.

=item C<-d>

Cross filesystem boundaries.  By default, B<sp> only scans
subdirectories that are in the same filesystem as the parent
directories specified on the command line.  This option has the
opposite meaning of B<du>'s C<-d> option.

Note that if the directories specified on the command line are not all
on the same filesystem, they will still all be searched, even if the
C<-d> option is not present.  This is not a bug; it's a feature.

=item C<-f>

Process symbolic links by using the file or directory which the
symbolic link references, rather than the link itself.  This is like
the C<-L> option of B<du>.

=item C<-H>

Format the space report in HTML as table rows rather than plain text. 
By default, the <TABLE> and </TABLE> tags are omitted.  The idea is
that the user will include the generated HTML in CGI output or in an
existing HTML file and may want to provide their own <TABLE> tags.

=item C<-T>

Include <TABLE> ...  </TABLE> HTML tags when formatting the report as
HTML.  In the absence of the C<-H> or C<-R> option, this option has no
effect.

=item C<-R> I<rows>

Instead of writing to I<stdout>, write to one or more HTML files.
Each HTML file will contain no more than the specified number of rows.
By default, the HTML files will be written in the current working
directory, and each filename will begin with C<"sp">.  This prefix can be
changed via the C<-P> option.  This option implies C<-H>.

=item C<-P> I<prefix>

Use the specified I<prefix>, rather than the default C<"sp"> for HTML
files.  This option is ignored unless C<-R> is present.

=item C<-c> I<cols>

Force output width to the specified number of columns.  Values smaller
than 34 will be silently rounded up to 34.  To achieve the specified
width, directory names will be truncated on the right, and
subdirectory/file names will be truncated from the left as necessary. 
By default, the output width is autoscaled so that the longest path
can be displayed without truncation.  This option only affects plain
text report formatting.

=item C<-m> I<size>

Exclude files or subdirectories that consume less than the specified
number of KB from the report.  The default is 1024, which seems to
work well for most large directory trees.  If you are analyzing a
small directory tree (like a single user's home directory), you may
wish to lower this to 256, but anything much smaller is likely to
cause all but the largest systems to run out virtual memory when
processing a large directory structure.

=item C<-i> I<pattern, ...>

This is a comma separated list of Perl regular expressions which will
be applied to each directory that B<sp> searches.  If C<-i> is
specified, only subdirectories that match at least one pattern will be
searched and subsequently included in the report.  This option is
usually used to prune the directories searched to reduce output size
and run-time.

=item C<-x> I<pattern, ...>

Like C<-i>, this is a comma separated list of Perl regular
expressions.  Subdirectories that match any of the patterns will not
be searched or included in the report.

=head1 SEE ALSO

L<du>, L<df>

=head1 AUTHOR

David C. Snyder <dsnyder0cnn@gmail.com>
