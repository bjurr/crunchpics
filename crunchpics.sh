#!/bin/bash
# This script will go through a path and pull out all picture files it will
# find recursively. It will gather as much info as it can about the file and
# put it in a small database. The image path will be sliced and diced to try
# to make meaningful tags out of it, and then put in the db as a CSV-like
# string (semi-column seperated). If the file was not already in the database
# (same checksum and size), it will then move the file in a single folder and
# rename it using it's md5 as a unique name (no use for filenames, we got tags)
#
# -*- coding: utf-8 -*-

DESTINATION=''
DB_FILENAME="crunchpics.db"
STAT_CMD="stat --format=%s"

# Test which version of stat we have (the one on OSX is very different than what
# I have under linux).
if ! [ $(${STAT_CMD} $0 2>/dev/null) ]; then
    STAT_CMD="stat -f %z"
    if ! [ $(${STAT_CMD} $0 2>/dev/null) ]; then
        echo "ERROR: Cannot use this version of stat."
        exit 1
    fi
fi

# Check if we have sqlite3 installed
if ! [ `which sqlite3` ]; then
    echo "Required package sqlite3 cannot be found."
    exit 1
fi

# The usual "help print" text
function usage {
    cat << EOF
usage: $0 [OPTIONS] FOLDER1 FOLDER2 ...

This script will analyze the content of the passed folders to find duplicates

OPTIONS:
   -h      Show this message
   -d      Database filename (default: $DB_FILENAME)
   -c      Folder where unique files must be copied to
EOF
}

# If we don't have enough parameters, show the help screen and gtfo.
if [ $# -lt 1 ]; then
    usage
    exit 1
fi

# Check which options were passed in
while getopts "hc:d:" opt; do
    case $opt in
        h)
            usage
            exit 1
            ;;
        c)
            DESTINATION=$OPTARG
            ;;
        d)
            DB_FILENAME=$OPTARG
            ;;
        \?)
            echo "Invalid option: -$OPTARG"
            exit 1
    esac
done

# Check if we have at least 1 folder to work with
if [ $# -lt $OPTIND ]; then
    echo "No folder specified."
    usage
    exit 1
fi

# Verify if the folders are valid
for folder in ${@:$OPTIND}; do
    if ! [ -d $folder ]; then
        echo "Folder ${folder} does not exist."
        exit 1
    fi
done

# Create the destination folder if we need to
if [ $DESTINATION ] && ! [ -d ${DESTINATION} ]; then
    echo "Destination folder doesn't exist. Creating it."
    mkdir -p ${DESTINATION}
fi

# Check if the database file already exist. It's valid to append more data to
# the database.
if [ ! -e ${DB_FILENAME} ]; then
    # Create the database. A table (Pictures) to hold the infos, and a table
    # (Types) to list the file types.
    SQL_STATEMENT=" CREATE TABLE Pictures(  Id INTEGER PRIMARY KEY ASC,
                                            Filename TEXT,
                                            Path TEXT,
                                            Type INTEGER,
                                            Size INTEGER,
                                            Shasum TEXT,
                                            Tags TEXT,
                                            Dupes INTEGER);
                    CREATE TABLE Types( Id INTEGER PRIMARY KEY ASC,
                                        Type TEXT);"
    sqlite3 ${DB_FILENAME} "${SQL_STATEMENT}"

    if [ $? -ne 0 ]; then
        echo "ERROR: Could not create Pictures sqlite database."
        exit 1
    fi
else
    echo "Reusing existing database: ${DB_FILENAME}"
fi

# These counters will get incremented every time we process a file. They are
# used to display progress.
FILES_PROCESSED=0
FILES_INSERTED=0

# Loop through the folders that were passed as arguments. Multiple folders can
# be specified, so that's why we start after the last option up to the end.
# This has been split in 2 steps because it was wreaking havoc with the IFS.
for folder in ${@:$OPTIND};do
    # Set the field seperator on newlines, otherwise the results from find will
    # be splitted on every spaces.
    IFS=$'\n'

    for fullpath in `find $folder`; do
        
        # If it's not a folder, analyze the file.
        if [ ! -d ${fullpath} ]; then
            EXTENSION=`echo ${fullpath} | sed -e 's/.*\(\..*\)/\1/g'`
            TYPE=`file -b "${fullpath}" | sed -e "s/'/''/g"` # Double single quotes for sqlite
            #SIZE=`$STAT_CMD ${fullpath}` # No idea why that doesn't work .... IFS screwup
            SIZE=`stat -f %z "${fullpath}"`
            SHASUM=`shasum "${fullpath}" | cut -b 1-40`
            NAME=`echo ${fullpath} | sed -n "s/.*\/\(.*\)/\1/p" | sed -e "s/'/''/g"` # Double single quotes for sqlite`
            TAGS=`echo ${fullpath} | sed -n "s/\(.*\)\/.*/\1/p" | sed -e "s/\//;/g" | sed -e "s/'/''/g"` # Double single quotes for sqlite`
            IMGPATH=`echo ${fullpath} | sed -e "s/'/''/g"` # Double single quotes for sqlite`

            # Add the Type to the database if it wasn't there already
            TYPE_ID=`sqlite3 ${DB_FILENAME} "SELECT Id FROM Types WHERE Type='${TYPE}';"`
            if ! [ ${TYPE_ID} ]; then
                # Insert the type in the db and retrieve the row id
                SQL_STATEMENT="INSERT INTO Types VALUES(NULL, '${TYPE}'); SELECT last_insert_rowid();"
                TYPE_ID=`sqlite3 ${DB_FILENAME} ${SQL_STATEMENT}`
                if [ $? -ne 0 ]; then
                    echo "ERROR: Could not perform the following operation:"
                    echo "${SQL_STATEMENT}"
                    exit 1
                fi
            fi

            # Query the db to see if we have a matching file already
            EXISTING=`sqlite3 ${DB_FILENAME} "SELECT Id,Tags,Size FROM Pictures WHERE Shasum='${SHASUM}' AND Size=${SIZE};"`

            if [ ${EXISTING} ]; then
                echo "${FILES_PROCESSED} - Updating:  ${fullpath}"
                EX_ID=`echo ${EXISTING} | cut -d'|' -f1`
                EX_TAGS=`echo ${EXISTING} | cut -d'|' -f2`
                EX_SIZE=`echo ${EXISTING} | cut -d'|' -f3`
                NEW_TAGS=`echo -n "${EX_TAGS}${TAGS};" | tr ';' '\n' | sort -u | tr '\n' ';' | sed -e "s/'/''/g"` # Double single quotes for sqlite`

                # Update the database with more tags (if any)
                SQL_STATEMENT="UPDATE Pictures set Tags='${NEW_TAGS}',Dupes=Dupes+1 where Id=${EX_ID};"
                sqlite3 ${DB_FILENAME} ${SQL_STATEMENT}
                if [ $? -ne 0 ]; then
                    echo "ERROR: Could not perform the following operation:"
                    echo "${SQL_STATEMENT}"
                    exit 1
                fi
            else
                echo "${FILES_PROCESSED} - Inserting: ${fullpath}"
                # New entry. Insert into the database.
                SQL_STATEMENT="INSERT INTO Pictures VALUES(NULL, '${NAME}', '${IMGPATH}', '${TYPE_ID}', '${SIZE}', '${SHASUM}', '${TAGS};', 0);"
                sqlite3 ${DB_FILENAME} ${SQL_STATEMENT}
                if [ $? -ne 0 ]; then
                    echo "ERROR: Could not perform the following operation:"
                    echo "${SQL_STATEMENT}"
                    exit 1
                fi
                let FILES_INSERTED=$FILES_INSERTED+1

                # If the "copy to destination" option was set, copy the file to
                # its new destination using the md5 as a name to avoid name
                # clashing.
                if [ $DESTINATION ]; then
                    cp "${fullpath}" ${DESTINATION}/${SHASUM}-${SIZE}${EXTENSION}
                fi
            fi
            let FILES_PROCESSED=$FILES_PROCESSED+1
        fi
    done;
    unset IFS
done;

NB_FILES=`sqlite3 ${DB_FILENAME} "SELECT COUNT(*) FROM Pictures;"`
NB_TYPES=`sqlite3 ${DB_FILENAME} "SELECT COUNT(*) FROM Types;"`
echo "-------------------------------"
echo "Processing completed."
echo "-------------------------------"
echo "${FILES_PROCESSED} files processed."
echo "${FILES_INSERTED} new."
echo "$(($FILES_PROCESSED-$FILES_INSERTED)) duplicates."
echo "${NB_FILES} unique entries in database currently."
echo "${NB_TYPES} types found total."
exit 0