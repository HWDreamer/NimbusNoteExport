# patchExport.pl, version 1.1.1

## Overall Procedure
1.  Make the tags database.  On the Ubuntu OS, run findTags.pl.  This script
will open Nimbus notes and then create a database of tags and dates. This
takes about 3 hours to process 500 notes.

2. Use FileZilla to move the database to
/cygdrive/d/sprin/GoogleDrive/NimbusNote/NimbusTags.db.
Create a backup copy with the date in the filename.

3. Make the Nimbus Note export files.  In the Nimbus app on the desktop select,
File,  Export all pages, select HTML icon, pick the working directory,
/cygdrive/d/sprin/GoogleDrive/NimbusNote/, for the save-to directory,
and then click the Export button.  Rename this new directory with a name
that includes the date.

4. Move the Alton Brown, Trip Computer and any sub folders out of HWDreamer
(the parent folder) and into the root folder, All Notes.  (These 2 sub
folder were correctly placed in a parent folder, however to easy processing,
they are processed as their own folder and then later moved into the true
parent folder.) If there are folders with the same name, suggest that you
rename all folder with unique names; later you can rename folders in
UpNote.

5. Copy this folder with All Notes to the work directory,
/cygdrive/d/sprin/GoogleDrive/NimbusNote/wrk\_copy\_as\_HTML/"All Notes"/.

6. Run patchExport.pl.  This will patch each of the folders of All Notes
directory.  Runs about 3.9 minutes.

7. Prepare UpNote.  Open UpNote. Go to the NOTEBOOKS side panel and create the
folder structure (including nested folders) that match Nimbus Note.

8. Import into UpNote.  Type Ctrl+/ to open Settings.  Pick 'General' from the
left panel.  Scroll down and click 'Import from HTML'.  Set the options:
      - OFF  Convert folder to a note book
      - ON   Use file name as the title
      - ON   Keep original creation and mod date
      - ON   Auto detect & create Hashtags
      - (Select the notebook)   Add to Notebook.

      - Select Folder, navigate to the export dir with the name of the note
      book, like "D:/NimbusNote/wrk\_copy\_as\_HTML/All Notes/Alton Brown"

      - 'Import Notes'.

  **Repeat this import for each notebook.**

9. Export notes from UpNote.  Type Ctrl+/ to open Setting.  Pick 'General' from
the left panel.  Scroll down and click 'Export all notes', then select the
directory for the files, like 'D:/NimbusNote/upnote-export'

10. Run patchExport.pl --check to get a list of possible problems.
