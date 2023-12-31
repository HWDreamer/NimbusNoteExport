#!/usr/bin/perl

# This script written for Ubuntu 22.04 OS.  It controls a web browser version
# of Nimbus Note.  This allows access to information about each note.

# Find and store the information used in the Nimbus notes, but is not exported
# by Nimbus.  This information is stored in a SQLite database and is used
# later to reinstated tags, creation date, and folders in another notes
# application.
#
#2023-11-30 Richard Springer
#2023-12-13 Web site added ad; code to close popup added to
#           openNimbusNote(). Added the --skip=<a-note-title> to skip before
#           storing notes.
#2023-12-17 Added Folders.fParent field to DB to hold the 'path' to a folder,
#           aka notebook. This with the folder's name are unique.


use strict;
use warnings;

use Carp              qw( cluck  croak  confess );
use Data::Dump::Color;
use Date::Format      qw(  time2str  );
use Date::Parse;
use DBD::SQLite;
use File::Basename;
use Getopt::Long;
use IPC::Run3;
use Selenium::Chrome;
use Selenium::Firefox;
use Selenium::Remote::WDKeys;
use Selenium::Waiter  qw( wait_until  );
use Term::ANSIColor   qw( :constants );
use Text::CSV_XS      qw( csv );
use Time::HiRes       qw( gettimeofday   sleep    tv_interval );



# Prototype Subroutine
sub createDB;             #line 170
sub findAFolderID;        #line 257
sub findANoteID;          #line 338
sub findATagID;           #line 395
sub findElementAndWait;   #line 473
sub NB;                   #line 524
sub openDB;               #line 564
sub openFirefox;          #line 595
sub openNimbusNote;       #line 632
sub printDatabase;        #line 690
sub printHelp;            #line 763
sub runListOfNotes;       #line 798
sub scrapeInfoPopup;      #line 899
sub scrapeNoteBody;       #line 968
sub scrapeTitleCard;      #line 1014
sub timestampTable;       #line 1064
sub waitForPageToLoad;    #line 1094


# Globals
our $VERSION = '1.2.2';
my $NIMBUS_URL = 'https://nimbusweb.me/'; #public page for Nimbus Note.
my $DB_FN = 'NimbusTags.db';              #SQLite DB we are making.
my $CFG_FN = 'nimbus.cfg';

my $DBH;           #database object handle
my $DRIVER;        #Selenium Web Driver handle
my $Time_Zero;     #time of day when we started a stopwatch

# Command line global variables and their defaults
my $optJustDump    = 0; #print the database only.
my $optSkipToTitle = ''; #skip down to this title
my $help           = 0; #print a command summary and exit
my $debug          = 0; #report progress information



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
               "dump!"       => \$optJustDump,
               "skip=s"      => \$optSkipToTitle,
               "help!"       => \$help,
               "debug!"      => \$debug,
              ) or $help = 1;

    if ($help) {
        printHelp();
        exit(0); #Unix "pass"
    }


#
# Open Selenium/Firefox to get the my Nimbus Note account.  That should
# display all my current note titles in a browser.  Run down the list of
# titles gathering info about each note.
#

    #dump. SQL: % is zero or more chars; _ is one char; not case sensitive
    if ($optJustDump) { openDB(); printDatabase('%'); exit; }

    # Open the database and create the tables if necessary.
    if ($optSkipToTitle eq '') {
        run3("rm -f $DB_FN*"); ## just remove and start over.
    } else {
        NB "Skipping down to the selected card.\n";
    }
    openDB();
    createDB();

    # Open a browser and get my Nimbus notes.
    openNimbusNote();

    # Go thru the list of note titles and gather our information about each
    # note and write that to the database.
    runListOfNotes();

} #end main



END {

    # Preserve error code by making the END subroutine's version temporary.
    # So now the incoming error code will be returned to Unix.
    local $?;

    # Close the database if there is one open
    if (defined $DBH) {
        undef $DBH; #best way to close a DB
    }

    # We are done with Selenium and Firefox
    if (defined $DRIVER) {
        $DRIVER->shutdown_binary(); #the approved way to close Firefox
        undef $DRIVER;
    }

    # Print the run time
    my $rtime = Time::HiRes::tv_interval($Time_Zero);
    my $hours   = int($rtime / 3600);
    $rtime = $rtime - ($hours * 3600);
    my $minutes = int($rtime / 60.0);
    my $seconds = $rtime % 60;
    if ($hours == 0) {
        printf("--- %dm %02ds %s run time ---\n\n",
               $minutes, $seconds, basename($0));
    } else {
        printf("--- %dh %2dm %02ds %s run time---\n\n",
               $hours, $minutes, $seconds, basename($0));
    }

} #end of END


#=======================================+=======================================
sub createDB {

# If our database does not exist, then create all its tables.  The major SQL
# instructions used here come from a Windows program, DbSchema.  The database
# schema was developed there, the DB is documented there, and it can generate
# the SQL commands.
#
# Given  [0]: the database handler for our thread

    my $stmt = <<"    EOT";
CREATE TABLE Folders ( 
	fID                  INTEGER NOT NULL  PRIMARY KEY  ,
	fName                TEXT NOT NULL    ,
	fParent              TEXT     
 );

CREATE TABLE Notes ( 
	nID                  INTEGER NOT NULL  PRIMARY KEY  ,
	nTitle               TEXT NOT NULL    ,
	nCreateDate          DATE  DEFAULT NULL   
 );

CREATE TABLE Tags ( 
	tID                  INTEGER NOT NULL  PRIMARY KEY  ,
	tName                TEXT NOT NULL    
 );

CREATE TABLE Utility ( 
	uKey                 TEXT NOT NULL  PRIMARY KEY  ,
	uValue               TEXT  DEFAULT 'NULL'   
 );

CREATE TABLE Folder2Notes ( 
	fnID                 INTEGER NOT NULL  PRIMARY KEY  ,
	fnFolderID           INTEGER NOT NULL    ,
	fnNoteID             INTEGER NOT NULL    ,
	FOREIGN KEY ( fnFolderID ) REFERENCES Folders( fID )  ,
	FOREIGN KEY ( fnNoteID ) REFERENCES Notes( nID )  
 );

CREATE TABLE Tag2Notes ( 
	tnID                 INTEGER NOT NULL  PRIMARY KEY  ,
	tnNoteID             INTEGER NOT NULL    ,
	tnTagID              INTEGER NOT NULL    ,
	FOREIGN KEY ( tnTagID ) REFERENCES Tags( tID )  ,
	FOREIGN KEY ( tnNoteID ) REFERENCES Notes( nID )  
 );

    EOT
    ;

    # If the database file does not exit, create one from scratch.  The above
    # $stmt is pasted from Window's DbSchema.  Great, except the 'do'
    # statement only executes 1 statement.
    if (-s $DB_FN) {
        my $rv;

        # Split the long $stmt into individual CREATE TABLE commands.
        $stmt =~ s/\n\s*\n\s*/\n/g; #multi newlines to one.
        $stmt =~ s/\s+,/,/g;        #spaces before commas are deleted.
        my @statments = split /CREATE TABLE/, $stmt;

        foreach (@statments) {
            next if $_ eq ''; #skip blank lines
            my $s = "CREATE TABLE IF NOT EXISTS" . $_; #add back the phrase+
            $rv = $DBH->do($s);

            if ($rv != 0E0) {
                NB "Error, did not CREATE tables. rv:$rv\n"
                  . "       Line " . __LINE__ . "  \n SQL:$s:\n";
            }
        }


        # Write a modification timestamp for each of the tables
        foreach (qw( Folders  Notes  Tags  Folder2Notes  Tag2Notes
                    )) {
            timestampTable($_);
        }
    } #end if (-s)

    return;
} #end createDB()



#===============================================================================
sub findAFolderID {

# Given the name of a notebook, look for an existing entry in the Folders
# table.  If not found, then insert this folder's name in the table.  In
# either case return with the Folders.fID number.
#
# Given [0]: string, the title of a folder.
#       [1]: string, the parent path to the folder
#       [2]: integer, note's nID.
#
# Return: integer, the fID of the note in the table.

    my $name   = $DBH->quote(shift);
    my $parent = $DBH->quote(shift);
    my $noteID = shift;

    my $stmt;
    my @result;
    my $rv;
    my $folderID;

    # Look for an existing Folder name in the database.
    $stmt = "SELECT * "
      . "FROM Folders "
      . "WHERE fName == $name "
      . "AND fParent == $parent "
      . ";"  ;
    @result = $DBH->selectall_array($stmt, { Slice => {} });
    my $rstCnt = scalar(@result);

    if ($rstCnt == 1) {
        # Already have 1 row matching the requested folder name.
        $folderID = $result[0]->{fID};

    } elsif ($rstCnt > 1) {
        NB "Error, there are $rstCnt matches of fName to $name\n";
        confess("ABORT; Too many Folder matches.\n");

    } else {
        # Normal, the folder name is not in the DB so enter it now
        $stmt = "INSERT INTO Folders "
          . "(fName, fParent ) "
          . "VALUES ($name, $parent) "
          . ";"  ;
        $rv = $DBH->do($stmt);
        if ($rv != 1) {
            # Not good, INSERT failed.
            my $str = sprintf( "The following Folder was not saved: %s.\n",
                               $name,
                             );
            NB "ERROR, $str\n";
            confess("ABORT, failed to write into database.\n");
        }
        $folderID = $DBH->last_insert_id();
        timestampTable('Folders');
        NB "Debug, new Folder.fID: $folderID\n" if $debug;
    }


    # Add entry to the link table, Folder2Notes.
    $stmt = "INSERT INTO Folder2Notes "
      . "(fnFolderID, fnNoteID) "
      . "VALUES ($folderID, $noteID) "
      . ";" ;
    $rv = $DBH->do($stmt);
    if ($rv != 1) {
        my $str = sprintf( "The following Folder2Notes was not used: %s.\n",
                           $name,
                         );
        NB "ERROR, $str\n";
        confess("ABORT, failed to write into database.\n");
    }
    timestampTable('Folder2Notes');


    return $folderID; #row ID of new entry
} #end findAFolderID()



#===============================================================================
sub findANoteID {

# Given the title of a note, look for an existing entry in the Notes table.
# If NOT found, then insert this note's title in the table.  If found, then
# give a warning and then create a new entry with same title.  In either case
# return with the new Notes.nID number.
#
# Given [0]: string, the title of a note.
#       [1]: string, note creation date.
#
# Return: integer, the nID of the note in the table.

    my $title = $DBH->quote(shift);
    my $cDate = $DBH->quote(shift);

    my $stmt;
    my @result;
    my $rv;

    $stmt = "SELECT * "
      . "FROM Notes "
      . "WHERE nTitle == $title "
      . ";"  ;
    @result = $DBH->selectall_array($stmt, { Slice => {} });

    if (scalar(@result) != 0) {
        # Already have some row matching the requested note title.  This is
        # just a warning since later the same titles will cause a problem.
        my $str = sprintf("There were %d entries already in the database, %s.\n"
                        .  "         A new entry will be made, but this is a "
                        .  "problem when dealing with the new Note app.\n",
                          scalar(@result), $title  );
        NB "Warning, $str";
        dd \@result; #row ID of existing entry
    }

    # The title is not in the DB so make an entry
    $stmt = "INSERT INTO Notes "
          . "(nTitle, nCreateDate) "
          . "VALUES ($title, $cDate) "
          . ";"  ;
    $rv = $DBH->do($stmt);
    if ($rv != 1) {
        my $str = sprintf( "The following Note was not used: %s.\n", $title );
        NB "ERROR, $str\n";
        confess();
    }
    my $id = $DBH->last_insert_id();
    timestampTable('Notes');
    NB "Debug, new Notes.nID: $id\n" if $debug;

    return $id; #row ID of new entry
} #end findANoteID()



#===============================================================================
sub findATagID {

# Given the name of a tag, look for an existing entry in the Tags table.  If
# NOT found, then insert this tag's name in the table.  In either case return
# with the Tags.tID number.
#
# Given [0]: string, the title of a tag.
#       [1]: integer, note's nID.
#
# Return: integer, the tID of the tag.

    my $name   = $DBH->quote(shift);
    my $noteID = shift;

    my $stmt;
    my @result;
    my $rv;
    my $tagID;

    # Look for an existing tag name in the database.
    $stmt = "SELECT * "
      . "FROM Tags "
      . "WHERE tName == $name "
      . ";"  ;
    @result = $DBH->selectall_array($stmt, { Slice => {} });
    my $rstCnt = scalar(@result);

    if ($rstCnt == 1) {
        # Already have 1 row matching the requested tag's name.
        $tagID = $result[0]->{tID};

    } elsif ($rstCnt > 1) {
        NB "Error, there are $rstCnt matches of tName to $name\n";
        confess("ABORT; Too many Folder matches.\n");

    } else {
        # The title is not in the DB so enter it now
        $stmt = "INSERT INTO Tags "
          . "(tName) "
          . "VALUES ($name) "
          . ";"  ;
        $rv = $DBH->do($stmt);
        if ($rv != 1) {
            # Not good, INSERT failed.
            my $str = sprintf( "The following Tag was not used: %s.\n",
                               $name,
                             );
            NB "ERROR, $str\n";
            confess("ABORT, failed to write into database.\n");
        }
        $tagID = $DBH->last_insert_id();
        timestampTable('Tags');
        NB "Debug, new Tags.tID: $tagID\n" if $debug;
    }


    # Add entry to the link table, Tag2Notes.
    $stmt = "INSERT INTO Tag2Notes "
      . "(tnNoteID, tnTagID) "
      . "VALUES ($noteID, $tagID) "
      . ";" ;
    $rv = $DBH->do($stmt);
    if ($rv != 1) {
        my $str = sprintf( "The following Tag2Notes was not used: %s.\n",
                           $name,
                         );
        NB "ERROR, $str\n";
        confess("ABORT, failed to write into database.\n");
    }
    timestampTable('Tag2Notes');


    return $tagID; #row ID of new entry
} #end findATagID()



#===============================================================================
sub findElementAndWait {

# Find an WebElement element and wait until it is enabled.  This is used mainly
# to extend the waitForPageToLoad by waiting until JavaScript enables the
# clickable element.
#
# Given [0]: the xpath to the element
#
# Return: the WebElement element, or undef if it did not become enabled in 30
#         seconds.

    my $xpath = shift;

    my $enable;
    my $visible;
    my $display;

    my $ele = $DRIVER->find_element($xpath);

    my $counter = 30; #a time-out down-counter, in seconds
    while (   !(
                   ($enable  =  $ele->is_enabled)
                && ($visible = !$ele->is_hidden)
                && ($display =  $ele->is_displayed)
               )
              && $counter >= 0)  {
        if ($debug) {
            if (!defined $display) { $display=0; } #bug patch
            print BRIGHT_BLUE ON_BLACK;
            printf( "(%02d): waiting for %s; e:%1d, v:%1d, d:%1d",
                    $counter, $xpath, $enable, $visible, $display );
            print RESET "\n";
        }
        sleep 0.84; #results in 1-second loops
        $counter--;
    }

    if ($counter < 0) {
        my $text = $ele->get_text();
        NB "Error, time-out waiting for element to become enabled.\n"
         . "       xpath: $xpath\n"
         . "       text: $text\n";
        return;
    }

    return $ele;
} #end findElementAndWait()



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



#===============================================================================
sub openFirefox  {

# Start a web browser session if one is not already running, The global
# variable $DRIVER will be pointing to the Selenium WebDriver.  The bash
# environment variable CN_BROWSER has the name of the browser to use.

    # Start Firefox if not already running. Start using WebDriver
    if (!defined $DRIVER) {

        my $brwsr =$ENV{'CN_BROWSER'};
        if (!defined($brwsr)) { NB "Debug, CN_BROWSER is not defined.\n"; }
        if (  !defined($brwsr)  ||  $brwsr =~ m/^f/i  ) { #starts with 'f'
            $DRIVER = Selenium::Firefox->new();
            NB "Debug, Using the Firefox browser.\n" if $debug;
        } else {
            $DRIVER = Selenium::Chrome->new();
            NB "Debug, Using the Chrome browser.\n" if $debug;
        }

    } else {
        NB "Web browser already exists; not starting a new one.\n";
    }

    #give up "finding" an element after 30 seconds
    $DRIVER->set_implicit_wait_timeout(30000);

    #NB, a better way of finding the location of a crash of the DRIVER in this
    #code is using Test::Selenium::Remote::Driver to define an error_handler.
    $DRIVER->error_handler( sub { print $_[1]; confess('goodbye'); } );
  #   $DRIVER->debug_on;

    return;
} #end openFirefox()



#=============================================================+=================
sub openNimbusNote {

# Start a browser and have it open my account on Nimbus Note.  Login to the my
# account and return with the standard desktop view of notes.

    my $id;
    my $ele;
    my @eles;
    my $xpath;

    # Open up Nimbus Note on a browser.
    openFirefox();
    $DRIVER->get($NIMBUS_URL);
    waitForPageToLoad();

    # They are pushing a popup ad; if there, then close it.
    $id = "//div [\@class='cb-close'] "; #the close "x" on the popup
    @eles = $DRIVER->find_elements($id);
    if (@eles) {
        $eles[0]->click();
        waitForPageToLoad();
    };

    # Go to the sign-in page.
    $id = 'Sign in'; #my account
    $ele = $DRIVER->find_element_by_partial_link_text($id);
    $ele->click();
    waitForPageToLoad();

    # Read whole config file into memory. (It's only one line of 2 args.)
    my $aoa = csv(in => $CFG_FN)  # reference to array of arrays
      or confess("Error with $CFG_FN: \n$!");

    # Name.  If there is not a input box then we are screwed.
    $ele = $DRIVER->find_element("//input[ \@name='login' ]" );
    $ele->clear(); #default text needs to be gone
    $ele->send_keys($aoa->[0][0]);

    # Password
    $ele = $DRIVER->find_element("//input[\@name='password']" );
    $ele->clear(); #default text needs to be gone
    $ele->send_keys($aoa->[0][1]);

    # OK
    $ele = $DRIVER->find_element("//button/span[text()='Sign in with email']");
    $ele->click();
    waitForPageToLoad();

    # Wait for a note's body to be loaded.
    $xpath = "//note-text-version-2/div/div[1]/div[2]/div[4]";
    $ele = findElementAndWait($xpath);

    return;
} #end openNimbusNote()



#=============================================================+=================
sub printDatabase {

    my $folderFilter = $DBH->quote(shift);

    my $stmt;
    my @result;


#
# Tool to print a list of notes with their folder and tags.
#

    print BOLD YELLOW " ========== "
      . "List of all note titles, their folders, and their tags"
      . " ========== " . RESET . "\n\n";

    $stmt = "SELECT * "
          . "FROM Notes "
          . "LEFT JOIN Folder2Notes ON fnNoteID == nID "
          . "LEFT JOIN Folders      ON fID == fnFolderID "
          . "WHERE fName LIKE $folderFilter "
          . ";"  ;
    @result = $DBH->selectall_array($stmt, { Slice => {} });

    foreach my $nt (@result) {
        # Get the list of tags for this note
        my $noteID = $nt->{nID};
        $stmt = "SELECT tName "
              . "FROM Tag2Notes "
              . "LEFT JOIN Tags ON tID == tnTagID "
              . "WHERE tnNoteID == $noteID "
              . ";"  ;
        my @tags = @{ $DBH->selectcol_arrayref($stmt) };
        my $tagList = join(', ', @tags);
        if (scalar(@tags)==0) { $tagList = '----'; };

        # Print this note
        printf(  "%s\n", $nt->{nTitle}  );
        printf(  ' 'x4 . "%s\n", $nt->{fName}  );
        printf(  ' 'x4 . "%s\n", $tagList  );
        print "\n";
    }


#
# Some hints on characters in note titles that will cause problems.
#

    print BOLD YELLOW "\n\n ========== "
      . "List note titles with problematic characters"
      . " ========== "  . "\n";

    print  " ========== "
      . "Includes colon, forward-slash, and double-quote"
      . " ========== " . "\n";

    print  " ========== "
      . "Nimbus changes the first 2 to an exclamation-mark"
      . " ========== " . RESET . "\n\n";


    foreach my $nt (@result) {
        if ( $nt->{nTitle} =~ m/[:\/!\"]/ ) {
            print "  $nt->{nTitle}\n";
        }
    }

    return;
} #end printDatabase()



#=============================================================+=================
sub printHelp {

# Print some information about this program and its command line options.

    my $pgName = fileparse($0);
    print <<"    EOT";

$pgName, version $VERSION

Scrapes some info about Nimbus Note cards that does not get transferred on an
export like tags and creation date.

NB: The note sub-folders need to be a unique name. Otherwise two sub-folders
    with the same name, but different parents, will be merged together.

The command line options are:

  --dump    List the data from the database then exit. (Normally after
            collection of the data, it is dumped, this option just does the
            printing.)
            (Default: --no-dump)
  --skip=string  Skip over note cards until reaching one matching (regex) this
            string.  This is used to restart an interrupted run.
  --debug   Print status information as the program progresses.
  --help    This message.

    EOT
    ;

    return;
}



#=============================================================+=================
sub runListOfNotes {

# Go down the list of note titles and gather information from both the title
# card and the note's body.

    my $xpath;
    my $ele;
    my $mDate;
    my $cDate;
    my $pnDate;
    my $title;
    my $parent;
    my $folder;

    # Bring attention to the panel with the list of note titles.
    $xpath = "//notes-list-view";
    my $ele_title_panel = $DRIVER->find_element($xpath);
    $ele_title_panel->click();

    # Set the start point by clicking on the first title card.
    $xpath = "//notes-list-view//div [\@class='notes-list-item--wrapper'] ";
    my @ele_notes = $DRIVER->find_elements($xpath);
    $ele_notes[0]->click();

    # Go through the list of note title cards gathering information.  Stop
    # looping if either $i exceeds its limit (a shorter development test), or
    # we are on the same (the last) title card again.
    my $i = 0;
    my @last_accessed = (0, 0, 0); # init element to fail 1st check
    my $doSkip = ($optSkipToTitle ne '');
    while ($i <= 500) { #safety; currently 404 notes in my account
        $i++;

        # Get the _active_ title card.
        $xpath = "//div [\@class='notes-list-item-wrapper active'] ";
        $ele = $DRIVER->find_element($xpath);

        # Gather information from this note's title card.  We are done looping
        # if this info is the same as the last card's.
        my @card = scrapeTitleCard($ele);
        ($title, $mDate, $pnDate) = @card;
        print "$i  Title: $title     Date:$mDate:$pnDate\n";

        if ( @last_accessed ~~ @card ) { last }
        @last_accessed = @card;

         # Just go to the next card if we have CL option to skip down to where
         # we left off.
        if ($doSkip ) {
            if ($title =~ m/$optSkipToTitle/i) {
                # we just found the card; start processing them.
                $doSkip = 0;
            } else {
                # this is not the card we are looking for, do not process it.
                goto NEXT_CARD;
            }
        }

        # Info from the information popup.
        ($parent, $folder, $mDate, $cDate) = scrapeInfoPopup();
        print "$i  Folder:$parent ;; $folder     Date:$mDate;$cDate\n" if $debug;

        # List the tags used on this note.
        my @tags = @{ scrapeNoteBody($ele) };
        dd \@tags if $debug;

        # Determine which creation to use.  If the Phat Note table exists,
        # then use that to get the creation date.  Otherwise use the one from
        # the Info Popup.
        if ($pnDate ne '') {
            NB "Debug, using Phat Notes' date.\n" if $debug;
            $cDate = $pnDate;
        } else {
            $cDate =~ s/, / /; #Nimbus puts in a comma between data and time
        }

        # Store this information in the database's tables.
        my $noteID = findANoteID($title, $cDate); # Write to Notes table
        my $bookID = findAFolderID($folder, $parent, $noteID); #folders &
                                                               #folder2Notes
        foreach (@tags) {
            my $tagID  = findATagID($_, $noteID); # Tags & Tag2Notes tables
        }


      NEXT_CARD:
        # Move to the next title card using a down-arrow to the enclosing
        # element (which accepts scroll events) of the title cards.
        $xpath =
          "//div [\@class='ReactVirtualized__Grid ReactVirtualized__List'] ";
        $ele = $DRIVER->find_element($xpath);
        $ele->send_keys(KEYS->{'down_arrow'});

    } #end while $i

    return;
} #end runListOfNotes()



#=============================================================+=================
sub scrapeInfoPopup {

# Click the "more" button (3-dots) and then select "Page info" from the list.
# This gives a popup panel with creation date, last used date, and folder.
# The popup is closed before returning with the dates and folder name.
#
# Given: void
#
# Return [0]: string, the parent folder's name or a zero-length string
#        [1]: string, the folder name
#        [2]: string, the last changed date, like "3/29/2007, 9:10:16 PM"
#        [3]: string, the created date,      like "3/29/2007, 9:10:16 PM"

    my $xpath;
    my $ele;
    my $folder = '';
    my $parent = '';
    my $mDate  = '';
    my $cDate  = '';

    # Find the 3-dot icon, select the "Page info" to create a popup.  This may
    # be out of view so mouse-over to ensure it's clickable.
    $xpath = "//svg-icon [\@icon='more'] ";
    $ele = $DRIVER->find_element($xpath);
    $DRIVER->release_general_action(); #clear the action queue
    $DRIVER->mouse_move_to_location(element => $ele);
    $DRIVER->general_action(); #force mouse-move to execute
    $ele->click(); #open popup menu

    $ele = $DRIVER->find_element_by_link_text('Page info');
    $ele->click(); #open information panel
    $xpath = "//div [\@class='nimbus-popup-close'] ";
    findElementAndWait($xpath); #wait of popup to fill
                            # div with "row breadcrumbs" is same as div[5]
    $xpath = "//note-info-popup/div/div/div/div[\@class='row breadcrumbs']";
    $ele = findElementAndWait($xpath); #wait for popup's folder line
    sleep 1.0;

    # Select the folder's name on the information panel
    $xpath = "//div [\@class='breadcrumbs__items ng-scope'] ";
    $ele = $DRIVER->find_element($xpath);
    $folder = $ele->get_text(); #folder like 'HWDreamer /  Alton Brown'
    if (  $folder =~ m/^(.+) \/\s+(.+?)$/   ) {
        # text was a path list, names separated by ' / '
        $parent = $1; #could be several names with ' / ' between them
        $folder = $2; #just the last folder's name
    }

    # Select the last-changed date on the information panel
    $xpath = "//note-info-popup/div/div/div/div[3]/label";
    $ele = $DRIVER->find_element($xpath);
    $mDate = $ele->get_text();

    # Select the creation date on the information panel
    $xpath = "//note-info-popup/div/div/div/div[4]/label";
    $ele = $DRIVER->find_element($xpath);
    $cDate = $ele->get_text();

    # Close the popup
    $xpath = "//div [\@class='nimbus-popup-close']";
    $ele = $DRIVER->find_element($xpath);
    $ele->click(); #click the close "X"

    return ($parent, $folder, $mDate, $cDate);
} #end scrapeInfoPopup()



#=============================================================+=================
sub scrapeNoteBody {

# From the screen of a note's body, select the tags icon in the upper tool
# bar.  On the resulting popup, select the list of note's current tags.  Close
# the popup and return the list.
#
# Given: the element <notes-list-view> of the current title card
#
# Return [0]: array pointer. Array of string tag names.

    my $ele_title_card = shift;

    my $xpath;
    my @eles;
    my @tags = ();


    # Open up the tags popup menu.  If this element does not exist, then there
    # are no tags currently assigned.  The scrapeInfoPopup() could have move
    # this out of view so mouse-over to ensure it's clickable.
    $xpath = "//svg-icon [\@tooltip-message='Change tags'] ";
    @eles = $DRIVER->find_elements($xpath);
    if (scalar(@eles) == 0) { return \@tags; }
    $DRIVER->release_general_action(); #clear the action queue
    $DRIVER->mouse_move_to_location(element => $eles[0]);
    $DRIVER->general_action(); #force mouse-move to execute
    $eles[0]->click();

    # Get a list of tags
    $xpath = "//div [\@class='selected-tags'] /div/span";
    @eles = $DRIVER->find_elements($xpath);

    foreach (@eles) {
        my $text = $_->get_text();
        push @tags, $text;
    }

    # Close the popup window by clicking elsewhere, i.e., our title card.
    $ele_title_card->click();

    return \@tags;
} #end scrapeNoteBody()



#=============================================================+=================
sub scrapeTitleCard {

# Given a title card element, pull the title text, the modification date, and
# if possible the Phat Notes creation date.  These 3 values are returned.
#
# Given [0]: the element <notes-list-view> of the current title card
#
# Return [0]: string, title of the note
#        [1]: string, the last modification date, like "11/28/2023" or blank
#        [2]: string, the Phat Note creation date, like "3/29/2007 9:10:16 PM"
#             or zero-length string.

    my $ele_title_card = shift;

    my $xpath;
    my $title;
    my $cDate;
    my $mDate;


    # Select the note's title
    $xpath = "./notes-list-item/div/div/div/"
      . "div[\@class='notes-list-item--title']/span";
    my $ele_title = $DRIVER->find_child_element($ele_title_card, $xpath);
    $title = $ele_title->get_text();

    # Select the note's modification date.
    $xpath = "./notes-list-item/div/div/div"
      . "/div[\@class='notes-list-item--content']/p/span[1]";
    my $ele_date = $DRIVER->find_child_element($ele_title_card, $xpath);
    $mDate = $ele_date->get_text();

    # If available, get the Phat Notes creation date
    $cDate = '';
    $xpath = "./notes-list-item/div/div/div"
      . "/div[\@class='notes-list-item--content']/p/span[2]";
    my @ele_date = $DRIVER->find_child_elements($ele_title_card, $xpath);
    if (scalar(@ele_date) != 0) {
        my $alt_date = $ele_date[0]->get_text();
        if ($alt_date =~ m/PN Created:([ \d\/:APM]+) PN Mod/) {
            $cDate = $1;
        }
    }

    return $title, $mDate, $cDate;
} #end scrapeTitleCard()



#=============================================================+=================
sub timestampTable {

# For the given table name, insert or replace its entry in the Utility table
# with the current time.

    my $tbl = shift; #name of a table in our database.

    my $now;
    my $stmt;
    my $rv;

    # Write a modification timestamp for each of the tables
    $now = time2str("%Y-%m-%d %T", time()); #like "2023-03-22 15:51:33" local
    $now = $DBH->quote($now);
    $tbl = $DBH->quote($tbl);
    $stmt = "INSERT or REPLACE INTO Utility "
          . "(uKey, uValue) VALUES ($tbl, $now);" ;

    $rv = $DBH->do($stmt);
    if ($rv != 1) {
        NB "Error, did not timestamp \"$tbl\" table. rv:$rv\n"
          . "       SQL:$stmt:\n";
        cluck();
    }
    return;
} #end timestampTable



#=============================================================+=================
sub waitForPageToLoad {

# Wait 30 seconds for a web page to load.  Uses the global $DRIVER. The
# wait_until function is part of the Selenium::Remote::Driver package.  It
# executes a Perl code block and returns its truthfulness unless the timeout
# occurs first.  Then the return is ''.
#
# The sleep times were determined by experimentation. The first is needed to
# get the old web page out and the new one started.  The final sleep is needed
# to compensate for other JavaScript parts still loading onto the page.
#
# Return boolean, "1" if page loaded, otherwise "".

    sleep(5.0);

    my $script = "return document.readyState";
    my $rtn = wait_until { $DRIVER->execute_script($script) eq 'complete' };
    if ($rtn != 1) {
        NB "ERROR, waitForPageToLoad() failed to 'complete'.\n";
    }

    sleep(1.0);
    return $rtn;
}



#=======================================+=======================================
