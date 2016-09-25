#!/bin/bash
# vim: set tabstop=2 shiftwidth=2 expandtab smartindent:
set -euo pipefail

# global variables
DRUSH=~drupaladmin/bin/drush
DT=$(/bin/date --utc +%Y-%m-%d.%H-%M-%S)
SKIP_TABLES_LIST=users_field_data
STRUCTURE_TABLES_LIST=backup_db,batch,cache_bootstrap,cache_config,cache_container,cache_data,cache_default,cache_discovery,cache_dynamic_page_cache,cache_entity,cache_flysystem,cache_menu,cache_render,cache_toolbar,cachetags,flood,history,queue,semaphore,sessions,watchdog

# relative paths
echo "Moving into /var/www/html directory ..."
cd /var/www/html
REL_PUBLIC_BACKUPS=sites/default/files/public-backups

# Make sure we are not leaking data by *not* backing up if the table structure has not been vetted.
# diff --unchanged-line-format= --old-line-format= --new-line-format='%5dn: %L' ...:
#   We make sure that the database does not contain any new tables that we don't already know about, and does not contain any differences with tables we do know about
#   We skip any tables that we know about, but are not yet in the database (why? b/c the cache tables are created on-demand)
# diff --line-format='%L' /dev/null ...:
#   If there is anything new or different from above, then print it and set the exit code to non-zero
DUMP_EXTRA='--no-data --no-create-db --skip-create-options --skip-lock-tables --compact'
DUMP_CMP=/var/lib/site/resources/sanitized-backup/database_structure.txt
echo "Comparing ${DUMP_CMP} against the output of the following to see if there are new or different tables: ${DRUSH} sql-dump --extra='${DUMP_EXTRA}'"
set +o pipefail
${DRUSH} sql-dump --extra="${DUMP_EXTRA}" | /usr/bin/diff --unchanged-line-format= --old-line-format= --new-line-format='%5dn: %L' ${DUMP_CMP} - | diff --line-format='%L' /dev/null - || exit 1
set -o pipefail

# Do the backup of the majority of tables
echo Creating ${REL_PUBLIC_BACKUPS}/${DT}.plain.sql.txt ...
${DRUSH} sql-dump --extra='--skip-comments' --structure-tables-list=${STRUCTURE_TABLES_LIST} --skip-tables-list=${SKIP_TABLES_LIST} --result-file=${REL_PUBLIC_BACKUPS}/${DT}.plain.sql.txt

# SECFIX.1: sql-dump --tables-list=xxx, if xxx does not exist, will dump all the tables. So we create uniquely named tables so no race condition attacks
SANTBL_UFD="san_$(echo $$ $(/bin/hostname) $(/bin/date +%s.%N) | /usr/bin/sha224sum | /usr/bin/awk '{print $1}')"
SANITIZED_TABLES_LIST="${SANTBL_UFD}"
function cleanup_sanitized {
    ${DRUSH} sql-query "DROP TABLE IF EXISTS ${SANTBL_UFD}"
}
trap cleanup_sanitized EXIT

# Create a sanitized table
echo "Sanitizing tables ..."
${DRUSH} sql-query "CREATE TABLE ${SANTBL_UFD} LIKE users_field_data"
${DRUSH} sql-query "INSERT INTO ${SANTBL_UFD}
    SELECT
        uid, langcode, NULL as preferred_langcode, NULL as preferred_admin_langcode,
	CASE WHEN name='' THEN '' ELSE SHA2(CONCAT(RAND(), name), 224) END as name,
	NULL as pass, NULL as mail,
	timezone, 0 as status,
	created, NULL as changed, created as access,
	NULL as login, NULL as init, default_langcode
    FROM users_field_data"

# Do the backup of sanitized tables
echo Creating ${REL_PUBLIC_BACKUPS}/${DT}.sanitized.sql.txt ...
${DRUSH} sql-dump --extra='--skip-comments' --tables-list=${SANITIZED_TABLES_LIST} --result-file=${REL_PUBLIC_BACKUPS}/.${DT}.sanitized.sql.unknown
if [ "$(/bin/grep '^CREATE TABLE' ${REL_PUBLIC_BACKUPS}/.${DT}.sanitized.sql.unknown | /usr/bin/wc -l)" != "1" ]; then
  # another failsafe in case the SECFIX.1 fails ... we should only have one (1) table!
  echo "SECFIX.1"
  exit 1
else
  # The webserver will not serve files with a leading dot "." nor with unknown extensions, which we did on purpose to mitigate SECFIX.1
  mv ${REL_PUBLIC_BACKUPS}/.${DT}.sanitized.sql.unknown ${REL_PUBLIC_BACKUPS}/${DT}.sanitized.sql.txt
fi

# Make sure the sanitized tables restore themselves
echo 'DROP TABLE IF EXISTS `users_field_data`;' >> ${REL_PUBLIC_BACKUPS}/${DT}.sanitized.sql.txt
echo 'RENAME TABLE `'"${SANTBL_UFD}"'` TO `users_field_data`;' >> ${REL_PUBLIC_BACKUPS}/${DT}.sanitized.sql.txt

# Cleanup gracefully now that we are done (rather than hope that EXIT trap works)
cleanup_sanitized

# Update the reference atomically
echo ${DT} > ${REL_PUBLIC_BACKUPS}/latest.txt.tmp
mv ${REL_PUBLIC_BACKUPS}/latest.txt.tmp ${REL_PUBLIC_BACKUPS}/latest.txt
echo Updated ${REL_PUBLIC_BACKUPS}/latest.txt. Done
