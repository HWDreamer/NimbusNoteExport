#!/usr/bin/perl

# This script was intended to run under Cygwin on a Windows 11 desktop PC which
# is able to export all notes from Nimbus Note to files.  Later these files
# are imported into UpNote running on the same system.  The only reason to run
# on Windows is that Windows file system has the Creation Date (a Windows
# feature) set for each note.

# Patch the export of notes from Nimbus Note so it can be imported into
# UpNote.  This involves these steps:
#  1. Unzip the Nimbus win-zip file leaving a folder name with the note's title.
#  2. Remove inadvertent hashtags by adding a space after the pound-sign.
#  3. Copy line by line the note.html file to a new file with the same name
#     as the folder.
#  4. During the copy look for the start of the note's body and there insert a
#     line with the tags.  The tags come from a database program findTags.pl.
#  5. Delete the original win-zip file.
#  6. Change the HTML file's date to match the note's creation date.
#
#2023-12-22 Richard Springer.

use strict;
use warnings;

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
sub addCreationDate;      #line 174
sub addTagsToNote;        #line 245
sub enhanceNimbusExport;  #line 352
sub NB;                   #line 422
sub openDB;               #line 462
sub printHelp;            #line 493
sub scrubNoteHashtags;    #line 585
sub unzipNote;            #line 616
sub validityCheck;        #line 665


# Globals
our $VERSION = '1.1.2';
my $WRK_DIR = '/cygdrive/d/sprin/GoogleDrive/NimbusNote/'; #working directory
my $VER_DIR = $WRK_DIR . 'wrk_copy_as_HTML/"All Notes"/'; #Copy of export dir
my $DB_FN   = $WRK_DIR . 'NimbusTags.db'; #Database with tags from Nimbus

my $PS_DIR;     #PowerShell version of export dir
my $DBH;        #database object handle
my $Time_Zero;  #date/time when we started a stopwatch

# Command line global variables and their defaults
my $optCheck     = 0; #print validity checks and exit
my $help         = 0; #print a command summary and exit
my $debug        = 0; #report progress information



{ #main

    # Start a timer to measure execution time.
    $Time_Zero = [Time::HiRes::gettimeofday]; #start timer
    my $dt = `date +"%F %T"`; #header for when recording in a log file
    $dt =~ s/\s+$//;          #remove end of line whitespace
    print "\n--- $dt ---\n";

    # Go to the command line and look for options.  Test test options for
    # consistency and setup global variables commanded by them.
    GetOptions( 
               "check!"      => \$optCheck,
               "help!"       => \$help,
               "debug!"      => \$debug,
              ) or $help = 1;

    if ($help) {
        printHelp();
        exit(0); #Unix "pass"
    }

    # Alter our Nimbus export directory path to be PowerShell like.
    $PS_DIR = $VER_DIR;
    $PS_DIR =~ s/\/cygdrive\/d\//D:\//;   # '/cygdrive/d/' --> 'D:/'
    $PS_DIR =~ s/\//\\/g;   #go with Windows back-slash for directory path
    $PS_DIR =~ s/"//g;      #double-quoted removed.
    # Example:  D:\NimbusNote\wrk_copy_as_HTML\All Notes\

    # Open the a database created by another Perl script from Nimbus Note
    # pages.
    openDB();

    # Command Line option to run validity checks on the database.
    if ($optCheck) {
        validityCheck;
        exit;
    }

    # Get a list of Nimbus note folders.  These are separate directories in
    # the Nimbus export.
    my @dirlist;
    my $cmd = "cd $VER_DIR && /usr/bin/ls -1";
    run3($cmd, \undef, \@dirlist);
    if ($?) { cluck("Error in system call:$cmd\n"); }

    # Foreach directory (each represents a note folder) ...
    foreach my $dir (@dirlist) {
        $dir =~ s/[\n\r\s]+$//; #remove EOL garbage
        print BRIGHT_YELLOW "$dir" . RESET . "\n";

        # Find the folder's ID number.  This is a unique number that holds the
        # folders notebook path and note name. (Possible to have sub-notebooks
        # with the same name.  This ID avoids confusion.)
        my $stmt = "SELECT * "
          . "FROM Folders "
          . "WHERE fName == \"$dir\" "
          . ";"  ;
        my @rows = $DBH->selectall_array($stmt, { Slice => {} });
        if (scalar(@rows) != 1) {
            dd \@rows;
            confess("ABORT, didn't find just 1 folder in database.\n"
                 .  "       see --help for suggestions.");
        }


        # Expand a zip files in a directory.  This will fill that directory
        # with sub-directories each with the name of a note's title.
        unzipNote($dir);

        # Modify each note's HTML file.  Change file's name, remove inadvertent
        # hashtags, add Nimbus tags, and add Nimbus creation date.
        enhanceNimbusExport($dir, $rows[0]->{fID});

    } #end foreach @dirList, i.e., each note folder
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
        printf("--- %dm %5.3fs %s run time. ---\n\n",
               $minutes, $seconds, basename($0));
    } else {
        printf("--- %dh %2dm %02ds %s run time. ---\n\n",
               $hours, $minutes, $seconds, basename($0));
    }

} #end of END


#=================================+=============================================
sub addCreationDate {

# Locate the Nimbus Note export file and change its creation dates to be the
# same as the database Notes.nCreatDate.  That data is the best we could
# determine as the original creation date/time of the note.

    my $noteName = shift; #filename from a directory listing
    my $hashRef  = shift; #database Notes and Folders entries for this note

    my $path;
    my ($mon, $day, $yr, $hr, $min, $sec, $am);
    my $cmd;
    my $nimbusDate;             #source date from Nimbus Note
    my $unixDate;               #date as a Unix epoch
    my $winDate;                #date as wanted by Windows PowerShell

    # Assemble the full path to this file.  We point to the folder with the
    # note's title.  (The note has the same name with a .html extension is in
    # this folder.)
    $path = $PS_DIR . $hashRef->{fName} . '\\' . $hashRef->{nTitle};
    $path =~ s/\//\\/g;   #go with Windows back-slash after directories
    $path =~ s/\'/\'\'/g; #single-quoted path needs the internal ' as ''
    # Example path to a note folder:
    # D:\NimbusNote\wrk_copy_as_HTML\All Notes\Archive\Helen''s WiFi


    # Break down the date/time into its parts.
    $nimbusDate = $hashRef->{nCreateDate};
    my $md = '(\d+)\/(\d+)\/(\d+)';          #date format like "3/21/2021"
    my $mt = '(\d+):(\d+):(\d+)\s([APM]+)';  #time like "4:20:13 PM"
    if ($nimbusDate =~ m/^\s*$md\s+$mt$/ ) {
        $mon = $1;
        $day = $2;
        $yr  = $3;
        $hr  = $4;
        $min = $5;
        $sec = $6;
        $am  = $7;
    } else {
        # not good
        NB "Error, \"$nimbusDate\" failed date/time decode.\n";
	cluck("Warning, creation date not set for \"$path\".\n");
	return;
    }

    # Reassemble the date/time in a form for PowerShell.  This manipulates all
    # times in UTC for consistency, even though it's a local time-zone value.
    if ($am eq 'PM'  and  $hr < 12) {
        $hr += 12;
    }
    $unixDate = Date_to_Time($yr, $mon, $day, $hr, $min, $sec); # in UTC
    $winDate  = time2str('%d %B %Y %T', $unixDate, 'UTC');


    # PowerShell command line.  The command to the shell is double-quoted
    # allowing interpretation of dollar-signs.  The path is single-quoted
    # allowing spaces without modifications, but some titles have single-quote
    # in the name -- those need to changed to 2 single-quotes.
    $cmd = "PowerShell -c "
      . "\"Get-ChildItem '$path'  |"
      . "  ForEach-Object { \\\$_.CreationTime = ('$winDate') }\"";
    print BOLD CYAN ">>>$cmd<<<" . RESET . "\n" if $debug;
    run3($cmd, \undef);
    if ($?) { cluck("Error in system call:$cmd\n"); }

    return;
} #end addCreationDate()



#=================================+=============================================
sub addTagsToNote {

# Add a line to a Note that gives its UpNote hashtag and a description of the 

    my $noteName = shift; #filename from a directory listing.
    my $bookDir  = shift; #directory of the current notebook.
    my $hashRef  = shift; #database Notes and Folders entries for this note.

    my $foundEnd = 0;    #flag, ==1 found the end of the body of text
    my @tagList = ();    #list of tag name
    my $tagString = '';  #combined list of hash-tag names
    my $cmd;

    # Get the file name and open one for input and one for output. NB, that
    # the quote marks are not used in Unix.
    $noteName =~ s/[\n\r\s\/]+$//;             #remove EOL garbage
    my $noteDir = $bookDir . $noteName .  "/"; #HTML note's full directory path
    $noteDir =~ s/[\"]+//g;                    #make into Unix path name
    my $noteFn = $noteDir . "$noteName.html";  #new name of note file
    my $oldFn = $noteDir . 'note.html';        #old name of note file

    open( my $IN, '<', $oldFn )
      or confess "ABORT, could not open $oldFn for input\n$!\n";

    if (-e $noteFn) {
        # Our new file already exists -- delete it.
        $cmd = "rm -f \"$noteFn\"";
        run3 ($cmd, \undef);
	if ($?) { cluck("Error in system call:$cmd\n"); }
    }
    open( my $OUT, '>', $noteFn )
      or confess "ABORT, could not open $noteFn for output\n$!\n";


    # Check the title for a possible problem where illegal filename characters
    # were used in note's title.  Examples, "/" and ":"
    my $qTitle = $DBH->quote($noteName);
    if ($noteName =~ /!/) {
        NB "Warning, $qTitle has a '!'. This may be a problem "
         . "where it replaced a '/' or ':'.\n";
    }


    # Get the list of tags from the database used by this note name.
    my $stmt = "SELECT * "
             . "FROM Notes "
             . "  JOIN Tag2Notes ON tnNoteID == nID "
             . "  JOIN Tags      ON tID == tnTagID "
             ." WHERE nID == $hashRef->{nID} "
             . ";"  ;
    my @rows = $DBH->selectall_array($stmt, { Slice => {} });

    if (scalar(@rows) != 0) {
        foreach (@rows) {
            push (@tagList, '#' . $_->{tName}); #tag as a hash-tag
        }
        $tagString = join('  ', @tagList); #all tags in a string
        $tagString .= '<br/>';  #HTML line break between tags and date
    }


    #Get the Creation Date from the database.
    my $cDate = $hashRef->{nCreateDate};

    # Make a HTML line that includes the tags and Nimbus creation date.
    $tagString .=  "Nimbus creation date: $cDate";


    # Read one line at a time and write to the new filename while looking of
    # the end of body text.  When found insert our info line.
    while (<$IN>) {
        if (     (not $foundEnd) #true if still looking for end
             and  m/<\/body>/ #end-of-body text
           ) {
            #found the end of the body
            my $inLine = $_;    #save this line
            print $OUT '<div id="RAS-tags"><small><small>'
              . "$tagString"
              . "</small></small></div>\n";
            print $OUT $inLine;
            $foundEnd = 1;      #found the start of the body of text

        } else {
            print $OUT $_;
        }
    } #end while <IN>

    if (not $foundEnd) {
        NB "Error, did not find </body> tag in $noteName.\n"
         . "      Tags and Creation Date not added to note file.\n";
    }

    # Close the old and new files.
    close($IN);
    close($OUT);

    # Delete the old HTML file. (Two HTML files will confuse the import.)
    $cmd = "rm  \"$oldFn\"";
    run3($cmd, \undef);
    if ($?) { cluck("Error in system call:$cmd\n"); }

    return;
} #end addTagsToNote()



#=================================+=============================================
sub enhanceNimbusExport {

# For the given directory (a folder of notes) enhance each of the note.html
# files.  First, remove the incidental hashtags. Second, rename note.html to
# the name of the note's title.  Third add the Nimbus tags and creation date
# to the note's text.  Forth, change to Windows file's Created Date to that
# given in the DB.  (The tags and date are held in the database created by
# findTabs.pl.)

    my $dir = shift; #name of a directory. It's a Nimbus Note folder of notes.
    my $fID = shift; #the folder ID in the database.

    # Get a list of notes in this directory
    my $fDir = $VER_DIR . "\"$dir\"/"; #current Nimbus folder path, w/ quotes
    my $cmd = "cd $fDir  &&  /usr/bin/ls -d */;";
    my @notelist;
    my $err;
    run3($cmd, \undef, \@notelist, \$err);
    if ($err ne '') {
        NB "Error, failed to get list of notes in directory."
          ."       $cmd\n"
          ."       $err\n";
        return;
    }
    my $size = scalar(@notelist);
    if ($size < 1) {
        NB "ERROR, there are no notes to process.\n";
        return;
    }
    print "   There are $size note files to be processed.\n";

    # For each note, add tags, add creation date, and change filename.
    foreach my $noteName (@notelist) {
	# Clean up this line from the ls command
	$noteName =~ s/\/$//g;        #remove the trailing forward-slash
	$noteName =~ s/[\n\r\s]+$//g; #remove EOL characters

        # Get a database row describing this notes Notes and Folders table
        # entries.
        my $stmt = "SELECT * "
          . "From Notes "
          . "LEFT JOIN Folder2Notes ON fnNoteID == nID "
          . "LEFT JOIN Folders ON fID == fnFolderID "
          . "WHERE fID == $fID "
          . "  AND nTitle == \"$noteName\" "
          . ";"  ;
        my @result = $DBH->selectall_array($stmt, { Slice => {} });
        my $cnt = scalar(@result);
        if ($cnt != 1) {
            NB "Error, $stmt\n";
            dd \@result;
            confess("ABORT, found $cnt matches to should be 1.\n");
        }

        # Remove inadvertent hashtags from the HTML.
        scrubNoteHashtags($noteName, $fDir);

        # Add a line to the note with the correct hashtags and creation date.
        addTagsToNote($noteName, $fDir, $result[0]);

        # Change the Windows creation date.
        addCreationDate($noteName, $result[0]);

    } #end foreach $noteName
    return;
} #end enhanceNimbusExport()



#=================================+=============================================
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

    my $pgNamexxxxxxxx = fileparse($0);
    print << "    EOT";

$pgNamexxxxxxxx, version $VERSION

Prepares the Nimbus Note export for import into UpNote.  This process does the
following:
  1. Unzip the Nimbus win-zip file leaving a folder named after the note's
     title.
  2. Copy line by line the note.html file to a new file with the same name
     as the folder.
  3. During the copy look for the end of the note's body and there insert a
     line with the tags and the creation date.  The tags and date come from a
     database program findTags.pl.
  4. Delete the original win-zip file.
  5. Change the Window's HTML file's date to match the note's creation date.

Overall Procedure
- Make the tags database.  On the Ubuntu OS, run findTags.pl.  This script
  will open Nimbus notes and then create a database of tags and dates. This
  takes about 3 hours to process 500 notes.

- Use FileZilla to move the database to
  $DB_FN.
  Create a backup copy with the date in the filename.

- Make the Nimbus Note export files.  In the Nimbus app on the desktop select,
  File,  Export all pages, select HTML icon, pick the working directory,
  $WRK_DIR, for the save-to directory,
  and then click the Export button.  Rename this new directory with a name
  that includes the date.

- Move the Alton Brown, Trip Computer and any sub folders out of HWDreamer
  (the parent folder) and into the root folder, All Notes.  (These 2 sub
  folder were correctly placed in a parent folder, however to easy processing,
  they are processed as their own folder and then later moved into the true
  parent folder.) If there are folders with the same name, suggest that you
  rename all folder with unique names; later you can rename folders in
  UpNote.

- Copy this folder with All Notes to the work directory,
  $VER_DIR.

- Run $pgNamexxxxxxxx.  This will patch each of the folders of All Notes
  directory.  Runs about 3.9 minutes.

- Prepare UpNote.  Open UpNote. Go to the NOTEBOOKS side panel and create the
  folder structure (including nested folders) that match Nimbus Note.

- Import into UpNote.  Type Ctrl+/ to open Settings.  Pick 'General' from the
  left panel.  Scroll down and click 'Import from HTML'.  Set the options:
      OFF  Convert folder to a note book
      ON   Use file name as the title
      ON   Keep original creation and mod date
      ON   Auto detect & create Hashtags
      <Select the notebook>   Add to Notebook.

      Select Folder, navigate to the export dir with the name of the note
      book, like "D:/NimbusNote/wrk_copy_as_HTML/All Notes/Alton Brown"

      'Import Notes'.

  Repeat this import for each notebook.

- Export notes from UpNote.  Type Ctrl+/ to open Setting.  Pick 'General' from
  the left panel.  Scroll down and click 'Export all notes', then select the
  directory for the files, like 'D:/NimbusNote/upnote-export'

- Run $pgNamexxxxxxxx --check to get a list of possible problems.


The command line options are:
  --check   Run some checks on the database and then exit.  1) Report on notes
            in the database but not appearing in the UpNote export directory.
            2) List the notes in the database that do not have any tags.
  --debug   Print status information as the program progresses.
  --help    This message.

    EOT
    ;

    $Time_Zero = [Time::HiRes::gettimeofday]; #start timer
    return;
}



#=================================+=============================================
sub scrubNoteHashtags {

# Scrub away what look like hashtags in the HTML exports.  As a natural part
# of entering notes, incidental hashtags (like #2) are created.  So edit the
# files to replace ' #' with ' # ' which advert the automatic creation of a
# hashtag in UpNote.

    my $noteName = shift; #filename from a directory listing
    my $bookDir  = shift; #directory of the current notebook.

    my $out;
    my $err;
    my $noteFN = "\"note.html\"";
    my $tempFN = "\"tmp.html\"";

    my $cmd = "cd $bookDir\"$noteName\" "                 #cd to notebook's dir
      . "&& sed -E 's/ #([^ ])/ # \1/g' $noteFN > $tempFN " #re code hashtags
      . "&& mv -f $tempFN $noteFN;" ;                     #filename restored
    run3($cmd, \undef, \$out, \$err);
    if ($err ne '') {
	print ">>>$cmd<<<\n";
	NB "Error in scrub of hashtags.\n"
         . "      $err\n";
    }

    return;
} #end scrubNoteHashtags()



#=============================================================+=================
sub unzipNote {

# Given a directory (a folder with notes), unzip each of its sub-files.  This
# will result in new sub-directories each with the note's title as its name.
# If the sub-directory already exists, refresh with the files for the zip.

    my $dir = shift; #name of a directory (a folder of notes)

    my @ziplist;
    my $cmd;
    my $out;
    my $err;

    # Get a list of zip files in this directory.
    my $fdir = $VER_DIR . "\"$dir\"/"; #full Nimbus folder path, w/ quotes
    $cmd = "cd $fdir && /usr/bin/ls -1 *.zip";
    run3($cmd, \undef, \@ziplist);
    if ($?) { cluck("Error in system call:$cmd\n"); }
    my $size = scalar(@ziplist);
    print "   There are $size zip files to process.\n";
    if ($size < 1) { return }; #if all converted just go to next folder

    # For each of the zip files in the directory, unzip deleting the .zip
    foreach my $zipfile (@ziplist) {
        $zipfile =~ s/[\n\r\s]+$//;  #remove EOL garbage
        my $noteDir = $zipfile;
        $noteDir =~ s/\.zip//;       #.zip filename becomes directory name
        print "    $zipfile \n" if $debug;
        $cmd = "cd $fdir  &&  unzip -uo \"$zipfile\"  -d \"$noteDir\";";
        run3($cmd, \undef, \$out, \$err);

        if (length($err) != 0) {
            NB "ERROR, unzip of note failed.\n"
              . "       command: $cmd\n"
              . "       $err\n";

        } else {
            $cmd = "rm -f $zipfile"; #remove zip file
  ###       run3($cmd, \undef);
  ###	    if ($?) { cluck("Error in system call:$cmd\n"); }
        }
    } #end foreach zip file

    return;
} #end unzipNote()



#=============================================================+=================
sub validityCheck {

# Post-processing checks on the results.

    my $stmt;
    my @rows;
    my $out;
    my $err;

#
# Check that there is a .html file with a similar name as each note in the
# database.
#
    print BOLD YELLOW ON_BLACK "====== Notes without HTML ======="
      . RESET . "\n";

    # List ALL notes along with their folder name.
    $stmt = "SELECT * "
      . "FROM Notes "
      . "LEFT JOIN Folder2Notes ON fnNoteID == nID " #get the folder ID
      . "LEFT JOIN Folders ON fID == fnFolderID "    #get the folder name
      . "ORDER BY fName, nTitle "
      . ";"  ;
    @rows = $DBH->selectall_array($stmt, { Slice => {} });

    foreach my $row (@rows) {
        my $fn = $VER_DIR . $row->{fName} . "/"   #note folder
          . $row->{nTitle} . "/"                  #note's directory
          . $row->{nTitle} . ".html";             #note's HTML body
        $fn =~ s/\"//g; #make path plain without quotes
        my $cmd = "ls -1 \"$fn\"";
        run3($cmd, \undef, \$out, \$err);
        if ($err ne '') {
            # Bad, we did something wrong
            print " Could not find the note's HTML file:\n"
              . "    $err\n";
        }
    }


#
# List the notes that do not have any tag on them.  May want to alter the
# original notes.
#
    print BOLD YELLOW ON_BLACK "\n\n====== Notes without tags ======="
      . RESET . "\n";

    # Get all notes with their folder and tags.  If tags link is null, then
    # the note is added to the list.
    $stmt = "SELECT * "
      . "FROM Notes "
      . "LEFT JOIN Tag2Notes ON tnNoteID == nID "    #look for this to be NULL
      . "LEFT JOIN Folder2Notes ON fnNoteID == nID " #get the folder ID
      . "LEFT JOIN Folders ON fID == fnFolderID "    #get the folder name
      . "WHERE tnID IS NULL "
      . "ORDER BY fName, nTitle "
      . ";"  ;
    @rows = $DBH->selectall_array($stmt, { Slice => {} });

    foreach my $row (@rows) {
        printf "%21s :: %s \n",
          $row->{fName},
          $row->{nTitle},
          ;
    }

    return;
} #end validityCheck()



#=============================================================+=================
