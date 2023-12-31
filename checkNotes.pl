#!/usr/bin/perl

# Check that all the notes in the database where picked up in UpNote's
# import. To get ta list of UpNote notes, an export to HTML is done to a
# temporary directory.  That directory is then checked for a filename that
# matches the database note's name.
#
#2023-12-21 Richard Springer


use strict;
use warnings;
use lib ".";

use Carp              qw( cluck  croak  confess );
use Data::Dump::Color;
use Date::Calc        qw(  Date_to_Time  );
use Date::Format      qw(  time2str  );
use DBD::SQLite;
use File::Basename;
use Getopt::Long;
use IPC::Run3;
use Term::ANSIColor   qw( :constants );
use Time::HiRes       qw( gettimeofday   sleep    tv_interval );


# Prototype Subroutine
sub changeFileDates;      #line 137
sub checkFilenameExists;  #line 211
sub listAllDBNotes;       #line 269
sub NB;                   #line 290
sub openDB;               #line 330
sub printHelp;            #line 367


# Globals
our $VERSION = '1.0.2';
my $WRK_DIR = "/cygdrive/d/sprin/GoogleDrive/NimbusNote"; #working directory
my $UPNOTE_DIR = $WRK_DIR.'upnote-export/UpNote_2023-12-24/notebooks/';
my $NIMBUS_DIR = $WRK_DIR . 'wrk_copy_as_HTML/All Notes/'; #Copy of export dir
my $DB_FN = $WRK_DIR . 'NimbusTags.db'; #Database with tags from Nimbus

my $PS_DIR;     #PowerShell version of $NIMBUS_DIR.
my $DBH;        #database object handle
my $Time_Zero;  #time of day when we started a stopwatch

# Command line global variables and their defaults
my $optCheck       = 1; #check UpNote has all the note titles.
my $optChangeCDate = 0; #change Nimbus export created-date on its export files.
my $help           = 0; #print a command summary and exit.
my $debug          = 0; #report progress information.



{ #main

#
# Start a timer to measure execution time.
#
    $Time_Zero = [Time::HiRes::gettimeofday]; #start timer
    my $dt = `date +"%F %T"`; #header for when recording in a log file
    $dt =~ s/\s+$//;          #remove end of line whitespace
    print "\n--- $dt ---\n";


#
# Go to the command line and look for options.  Test test options for
# consistency and setup global variables commanded by them.
#
    GetOptions( 
               "check!"      => \$optCheck,
               "date!"       => \$optChangeCDate,
               "help!"       => \$help,
               "debug!"      => \$debug,
              ) or $help = 1;

    # Must give one of these options
    if (  not ($optCheck  or  $optChangeCDate)  ) {
	$help = 1;
    }

    if ($help) {
        printHelp();
        exit(0); #Unix "pass"
    }


#
# Get a list of all notes from our database.  Then either check that there is
# a file with the same name as the database's note title in the UpNote HTML
# export, or make the Nimbus export HTML file's creation date match the
# database's Notes.nCreateDate .
#

    openDB();
    my $rowRef = listAllDBNotes(); #Db query, list all its notes

    if ($optCheck) {
	checkFilenameExists($rowRef);  #check that export has same filename
    }


} #end main



END {

    # Preserve error code by making the END subroutine's version temporary.
    # So now the incoming error code will be returned to Unix.
    local $?;

    # Close the database if there is one open
    if (defined $DBH) {
        undef $DBH; #best way to close a DB
    }

    # Print the run time
    my $rtime = Time::HiRes::tv_interval($Time_Zero);
    my $hours   = int($rtime / 3600.0);
    $rtime = $rtime - ($hours * 3600.0);
    my $minutes = int($rtime / 60.0);
    my $seconds = $rtime - ($minutes * 60.0);
    if ($hours == 0) {
        printf("--- %dm %5.3fs %s run time ---\n\n",
               $minutes, $seconds, basename($0));
    } else {
        printf("--- %dh %2dm %02ds %s run time---\n\n",
               $hours, $minutes, $seconds, basename($0));
    }

} #end of END



#=============================================================+=================
sub changeFileDates {

# Go through the Nimbus Note export files and change their creation dates to
# be the same as the database Notes.nCreatDate.  That data is the best we
# could determine as the original creation date/time of the note.

    my $rowRef = shift;

    my $path;
    my ($mon, $day, $yr, $hr, $min, $sec, $am);
    my $cmd;
    my $nimbusDate; #source date from Nimbus Note
    my $unixDate;  #date as a Unix epoch
    my $winDate;   #date as wanted by Windows PowerShell

    # Alter our Nimbus export directory path to be PowerShell like
    $PS_DIR = $NIMBUS_DIR;
    $PS_DIR =~ s/\/cygdrive\/d\//D:\//; # '/cygdrive/d/' --> 'D:/'


    foreach my $row (@$rowRef) {
	# Break down the date/time into its parts
	$nimbusDate = $row->{nCreateDate};
	my $md = '(\d+)\/(\d+)\/(\d+)'; #date format like "3/21/2021"
	my $mt = '(\d+):(\d+):(\d+)\s([APM]+)'; #time like "4:20:13 PM"
	if ($nimbusDate =~ m/^\s*$md\s+$mt$/ ) {
	    $mon = $1;
	    $day = $2;
	    $yr  = $3;
	    $hr  = $4;
	    $min = $5;
	    $sec = $6;
	    $am  = $7;
	}
	else {
	    # not good
	    NB "Error, \"$nimbusDate\" failed date/time decode.\n";
	}

	# Reassemble the date/time in a form for PowerShell.  This manipulates
	# all times to be in UTC even though it's a local time-zone value.
	if ($am eq 'PM'  and  $hr < 12)  { $hr += 12; }
	$unixDate = Date_to_Time($yr, $mon, $day, $hr, $min, $sec); # in UTC
	$winDate  = time2str('%d %B %Y %T', $unixDate, 'UTC');

	# Assemble the full path to this file.  We point to the folder that
	# has the note's title.  (The note has the same name with a .html
	# extension is in this folder.)
    	$path = $PS_DIR . $row->{fName} . "/" . $row->{nTitle};
        $path =~ s/\//\\/g; #go with Windows back-slash after directories
	$path =~ s/\'/\'\'/g; #single-quoted path needs internal ' as ''


	# PowerShell command line.  The command is double-quoted to all
	# interpretation.  The path is single-quoted allowing spaces without
	# modifications, but some titles have single-quote in the name --
	# those need to changed to 2 single-quotes.
        $cmd = "PowerShell  -c "
	     . "\"Get-ChildItem '$path'  |"
	     . "  ForEach-Object { \\\$_.CreationTime = ('$winDate') }\"";
	print BOLD CYAN ">>>$cmd<<<" . RESET . "\n";
	run3($cmd, \undef);

    } #end foreach $row




    return;
} #end changeFileDates()



#=============================================================+=================
sub checkFilenameExists {

# For each of the databases note titles, check that the corresponding file
# exists in the UpNote export directory.  This is to ensure all notes were
# imported into UpNote.

    my $rowRef =  shift;

    my @stats;
    my $path;
    my $fullPath;
    #my @stats =($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
    #            $atime,$mtime,$ctime,$blksize,$blocks)

    my $missing = 0; #number of missing files.
    my $total = scalar(@$rowRef); #total number of files to be searched

    foreach my $row (@$rowRef) {
	# Form the folder's path to the note.
	if ($row->{fParent} eq '') {
	    $path = $row->{fName}; #just the folder's name, no parent
	} else {
	    $path = $row->{fParent};
            $path =~ s/\s+\/\s+/\//g;            #change ' / ' to '/'
	    $path = $path . '/' . $row->{fName}; #the path to our note
	}

	# The path and note title, like "HWDreamer/Alton Brown/Grilled Pizza"
	$path = $path . '/' . $row->{nTitle};

        # Make $path into the full filename that should appear in the UpNote
        # export.  This is the full path of a file on the PC.  Like:
	# /cygdrive/d/NimbusNote/upnote-export/UpNote_2023-12-21_08-53-25/
	#          notebooks/HWDreamer/Alton Brown/Grilled Pizza.html.lnk
        $fullPath =  $UPNOTE_DIR . $path . '.html.lnk';

        # Use stats() to detect the existence of the note file
        @stats = lstat($fullPath); #stat a link file
        if (scalar(@stats) == 0) {
            NB "ERROR, could not find  $path\n";
	    $missing++;
        } else {
            NB "Debug, found $path\n" if $debug;
        }
    } #end foreach @rows

    if ($missing == 0) {
	print BOLD GREEN "Missing none of the $total files.";
    }else {
	print BOLD YELLOW "Missing $missing of $total files.";
    }
    print  RESET . "\n";
    return;
} #end checkFilenameExists()



#=============================================================+=================
sub listAllDBNotes {

    my @rows;

    my $stmt = "SELECT * "
             . "FROM Notes "
             . "LEFT JOIN Folder2Notes ON fnNoteID == nID "
             . "LEFT JOIN Folders ON fID == fnFolderID "
             . "ORDER BY fParent, nTitle "
             . ";"  ;
    @rows = $DBH->selectall_array($stmt, { Slice => {} });

    my $count = scalar(@rows);
    NB "Debug, there are $count rows in the database.\n";

    return \@rows;
} #end listAllDBNotes()



#=============================================================+=================
sub NB {

# Print messages with a color highlight.  Highlight strings with "debug",
# "warning", "abort", or "error" with contrasting text color.  If no word is
# found, a "Note" string is added to the message.
#
# Given [0]: the string to print to STDOUT.
#
# Return: void

    my $message = shift;
    my $newlineFlag;  #set to add a newline at end of printed message

    #terminal does not like a RESET after the "\n" so remove "\n" for now.
    $newlineFlag = $message =~ s/\n$// ;

    if ($message =~ m/(abort|error)/i) {
        $message = BOLD RED ON_BLACK . $message . RESET;
        $newlineFlag = 1; #force a newline after this message's RESET

    } elsif ($message =~ s/(warn\w*)/${\BOLD YELLOW ON_BLACK}$1${\RESET}/i) {
        # Just the "Warning" is highlighted, not the whole string.

    } elsif ($message =~ m/^debug/i) {
        $message = BOLD GREEN . $message . RESET;
        $newlineFlag = 1; #force a newline after this message's RESET

    } else {
        # Just the added "Note" is highlighted, not the whole string
        $message = BOLD BLACK ON_WHITE . " Note " . RESET . " " . $message;
    }

    if ($newlineFlag) { $message .= "\n" }
    print $message;
    return;
} #end NB()



#=============================================================+=================
sub openDB {

# Open the database file.  The global $DBH will be set on return.  This
# routine will abort this program if something goes wrong.

    return if defined $DBH; #a db is already open

    # Check that the database file exists.
    if (not -e $DB_FN) {
	NB "Error, could not find database file $DB_FN.\n";
	confess ("ABORT, need database file to continue.\n");
    }

    # Open the data base
    my $dsn = "dbi:SQLite:dbname=$DB_FN"; #data source name
    $DBH = DBI->connect($dsn, "", "", {
                          PrintError         => 0,
                          RaiseError         => 1,  #don't need "or die()"
                          AutoCommit         => 1,  #no rollback
                                      })
        or croak "Database connect error!\n$DBI::errstr\n";

    # Performance base; we probably not sharing the DB with other scripts.
    $DBH->do("PRAGMA journal_mode = WAL;");
    $DBH->do("PRAGMA synchronous = NORMAL;");
    $DBH->do("PRAGMA page_size = 4096;"); #4K bytes per page
    $DBH->do("PRAGMA cache_size = 5000;");#5K pages --> 20MB cache
    $DBH->do("PRAGMA temp_store = MEMORY;"); #temp tables & indices in memory
    $DBH->do("PRAGMA mmap_size = 20000000;"); #20MB memory instead of r/w calls

 #  $DBH->{TraceLevel} =1; #more DBI debug to STDOUT
    return;
} #end openDB



#=============================================================+=================
sub printHelp {

# Print some information about this program and its command line options.

    my $pgName = fileparse($0);
    print <<"    EOT";

$pgName, version $VERSION

Uses the database we made from Nimbus Note to either change the creation date
on the export files, or to check that UpNote imported all the available note
files.

The command line options are:
  --check   Check that UpNote imported all the note files that are listed in
            our database. (Default: --check)
  --debug   Print status information as the program progresses.
  --help    This message.

    EOT
    ;

    return;
}



#=======================================+=======================================
