# Plowshare

## Introduction

Plowshare is a set of command-line tools (written entirely in Bash shell script) designed for managing file-sharing websites (aka Hosters).

Plowshare is divided into 6 scripts:
- *plowdown*, for downloading URLs
- *plowup*, for uploading files
- *plowdel*, for deleting remote files
- *plowlist*, for listing remote shared folders
- *plowprobe*, for retrieving information of downloading URLs
- *plowmod*, easy management (installation or update) of Plowshare modules

Plowshare itself doesn't support any websites (named *module*). It's just the core engine.
Concerning modules, few are available separately and must be installed in user directory (see paragraph below).

## Install

See `INSTALL` file for details.

## Usage examples

All scripts share the same verbose options:
> `-v0` (alias: `-q`),
> `-v1` (errors only),
> `-v2` (infos message; default),
> `-v3` (show all messages),
> `-v4` (show all messages, HTML pages and cookies, use this for bug report).

Getting help:
> `--help`
> `--longhelp` (*plowdown* & *plowup* only, prints modules command-line options)

Exhaustive documentation is available in manpages.

All examples below are using fake links.

### Plowdown

Download a file from Rapidshare:

```shell
$ plowdown http://www.rapidshare.com/files/86545320/Tux-Trainer_250108.rar
```

Download a file from Rapidgator using an account (free or premium).
Note: `:` is the separator character for login and password.

```shell
$ plowdown -a 'myuser:mypassword' http://rapidgator.net/file/49b1b874
```

Download a list of links (one link per line):

```shell
$ cat file_with_links.txt
# This is a comment
http://depositfiles.com/files/abcdefghi
http://www.rapidshare.com/files/86545320/Tux-Trainer_25-01-2008.rar
$ plowdown file_with_links.txt
```

Download a list of links (one link per line) commenting out (with `#`) those successfully downloaded:

```shell
$ plowdown -m file_with_links.txt
```

Download a file from Oron with Death by Captcha service:

```shell
$ plowdown --deathbycaptcha='user:pass' http://oron.com/dw726z0ohky5
```

Download a file from Rapidshare with a proxy (cURL supports `http_proxy` and `https_proxy` environment variables, default port is `3128`):

```shell
$ export http_proxy=http://xxx.xxx.xxx.xxx:80
$ plowdown http://www.rapidshare.com/files/86545320/Tux-Trainer_250108.rar
```

Download a file with limiting the download speed (in bytes per second). Accepted prefixes are: `k`, `K`, `Ki`, `M`, `m`, `Mi`.

```shell
$ plowdown --max-rate 900K http://www.rapidshare.com/files/86545320/Tux-Trainer_250108.rar
```

Download a file from Rapidshare (like firefox: append `.part` suffix to filename while file is being downloaded):

```shell
$ plowdown --temp-rename http://www.rapidshare.com/files/86545320/Tux-Trainer_250108.rar
```

Download a password-protected file from Mediafire:

```shell
$ plowdown -p 'somepassword' http://www.mediafire.com/?mt0egmhietj60iy
```

Avoid never-ending downloads: limit the number of tries (for captchas) and wait delays for each link:

```shell
$ plowdown --max-retries=4 --timeout=3600 my_big_list_file.txt
```

### Plowup

Upload a single file anonymously to BayFiles:

```shell
$ plowup bayfiles /tmp/foo.bar
```

Upload a bunch of files anonymously to 2Shared.
Note: `*` is a [wildcard character](http://en.wikipedia.org/wiki/Glob_%28programming%29) expanded by Bash interpreter. Here in this case: only files will be sent, subdirectories will be ignored.

```shell
$ plowup 2shared /path/myphotos/*
```

Upload a file to Rapidshare with an account (premium or free)

```shell
$ plowup -a 'myuser:mypassword' rapidshare /path/xxx
```

Upload a file to Mirrorcreator changing uploaded file name:

```shell
$ plowup mirrorcreator /path/myfile.txt:anothername.txt
```

Upload a file to MegaShares (anonymously) and set description:

```shell
$ plowup -d "Important document" megashares /path/myfile.tex
```

Upload a file to Oron anonymously with a proxy:

```shell
$ export http_proxy=http://xxx.xxx.xxx.xxx:80
$ export https_proxy=http://xxx.xxx.xxx.xxx:80
$ plowup oron /path/myfile.txt
```

Abort slow upload (if rate is below limit during 30 seconds):

```shell
$ plowup --min-rate 100k mediafire /path/bigfile.zip
```

Modify remote filenames (example: *foobar.rar* gives *foobar-PLOW.rar*):

```shell
$ plowup --name='%g-PLOW.%x' mirrorcreator *.rar
```

Be aware that cURL is not capable of uploading files containing a comma `,` in their name, so make sure to rename them before using *plowup*.

### Plowdel

Delete a file from MegaShares (*delete link* required):

```shell
$ plowdel http://d01.megashares.com/?dl=6EUeDtS
```

Delete files (deletes are successive, not parallel:

```shell
$ plowdel http://d01.megashares.com/?dl=6EUeDtS http://depositfiles.com/rmv/1643181821669253
```

Delete a file from Rapidshare (account is required):

```shell
$ plowdel -a myuser:mypassword http://rapidshare.com/files/293672730/foo.rar
```

### Plowlist

List links contained in a shared folder link and download them all:

```shell
$ plowlist http://www.mediafire.com/?qouncpzfe74s9 > links.txt
$ plowdown -m links.txt
```

List two shared folders (first URL is processed, then the second one, this is not parallel):

```shell
$ plowlist http://www.mediafire.com/?qouncpzfe74s9 http://www.sendspace.com/folder/5njdw7
```

Some hosters are handling tree folders, you must specify `-R`/`--recursive` command-line switch to *plowlist* for enabing recursive lisiting.

List some Sendspace web folder. Render results for vBulletin *BB* syntax:

```shell
$ plowlist --printf '[url=%u]%f[/url]%n' http://www.sendspace.com/folder/5njdw7
```

List links contained in a dummy web page. Render results as HTML list:

```shell
$ plowlist --fallback --printf '<li><a href="%u">%u</a></li>%n' \
      http://en.wikipedia.org/wiki/SI_prefix
```

### Plowprobe

Gather public information (filename, file size, file hash, ...) about a link.
No captcha solving is requested.

Filter alive links in a text file:

```shell
$ plowprobe file_with_links.txt > file_with_active_links.txt
```

Custom results format: print links informations (filename and size). Shell and [JSON](http://json.org/) output.

```shell
$ plowprobe --printf '#%f (%s)%n%u%n'  http://myhoster.com/files/5njdw7
```

```shell
$ plowprobe --printf '{"url":"%U","size":%s}%n' http://myhoster.com/files/5njdw7
```

Custom results: print *primary* url (if supported by hosters and implemented in module):

```shell
$ plowprobe --printf='%v%n' http://a5ts8yt25l.1fichier.com/
https://1fichier.com/?a5ts8yt25l
```

Use `-` argument to read from stdin:

```shell
$ plowlist http://pastebin.com/1d82F5sd | plowprobe - > filtered_list.txt
```

## Configuration file

Plowshare looks for `~/.config/plowshare/plowshare.conf` or `/etc/plowshare.conf` files.
Options given at command line can be stored in the file.

Example:
```
###
### Plowshare configuration file
### Line syntax: token = value
###

[[General]]
interface = eth1
captchabhood=cbhuser:cbhpass

rapidshare/a = matt:4deadbeef
mediafire/a = "matt:4 dead beef "
freakshare/b=plowshare:xxxxx

[[Plowdown]]
timeout=3600
#antigate=49b1b8740e4b51cf51838975de9e1c31

[[Plowup]]
max-retries=2
mirrorcreator/auth-free = foo:bar
mirrorcreator/count = 5

[[Plowlist]]
verbose = 3

#[[Plowprobe]]
```

Notes:
- Blank lines are ignored, and whitespace before and after a token or value is ignored, although a value can contain whitespace within.
- Lines which begin with a `#` are considered comments and ignored.
- Double quoting value is optional.
- Valid configuration token names are long-option command-line arguments of Plowshare. Tokens are always lowercase. For modules options, tokens are prepended by module name and a slash character. For example: `rapidshare/auth` is equivalent to `rapidshare/a` (short-option are also possible here). Another example: `freakshare/b` is equivalent to `freakshare/auth-free`.
- Options in general section prevail over `PlowXXX` section. Options given on the command line prevail over configuration file options.

You can disable usage of Plowshare config file by providing `--no-plowsharerc` command-line switch. You can also specify a custom config file using `--plowsharerc` switch.

## Use your own captcha solver

It is possible providing *plowdown* or *plowup* with `--captchaprogram` command-line switch followed by a path to a script or executable.

### Script exit status

- `0`: solving success. Captcha Word(s) must be echo'ed (on stdout).
- `$ERR_NOMODULE`: external solver is not able to solve requested captcha. Let *plowdown* continue solving it normally (will consider `--captchamethod` if specified).
- `$ERR_FATAL`: external solver failed.
- `$ERR_CAPTCHA`: external solver failed. Note: this exit code is eligible with retry policy (`-r`/`--max-retries`).

### Examples

Understanding example:

```shell
#!/bin/bash
# $1: module name
# $2: path to image
# $3: captcha type. For example: "recaptcha", "solvemedia", "digit-4".

declare -r ERR_NOMODULE=2
declare -r ERR_CAPTCHA=7

# We only support uploadhero, otherwise tell Plowshare to solve on its own
if [ "$1" != 'uploadhero' ](url=%u]%f[/url]%n'); then
    exit $ERR_NOMODULE
fi

# You can print message to stderr
echo "Module name: $1" >&2
echo "Image: $2" >&2

# Use stdout to send decoding result
echo "5ed1"
exit 0
```

Captcha emailing example:

```shell
#!/bin/bash
#
# Sends an email with image as attachment.
# Requires heirloom-mailx and not bsd-mailx.
#
# Here is my ~/.mailrc:
#
# account gmail {
# set from="My Name <xyz@gmail.com>"
# set smtp-use-starttls
# ssl-verify=ignore
# set smtp=smtp://smtp.gmail.com:587
# set smtp-auth=login
# set smtp-auth-user=xyz@gmail.com
# set smtp-auth-password="xxx"
# }

declare -r ERR_FATAL=1
declare -r MAILTO='xyz@gmail.com'

# Image file expected
if [ ! -f "$2" ]; then
    exit $ERR_FATAL
fi

BODY="Hi!

Here is a captcha to solve; it comes from $1."

mailx -A gmail -s 'Plowshare sends you an image!' \
    -a "$2" "$MAILTO" >/dev/null <<< "$BODY" || {
        echo 'mailx fatal error, abort' >&2;
        exit $ERR_FATAL;
}

echo 'Please check your email account and enter captcha solution here:' >&2
IFS= read -r
echo "$REPLY"
exit 0
```

Captcha FTP example:

```shell
#!/bin/bash
#
# Uploads the image to an FTP server in the LAN. If the server is not available
# (i.e. my computer is not running) or no CAPTCHA solution is entered for
# 15 minutes (i.e. I am occupied), let Plowshare try to handle the CAPTCHA.

declare -r MODULE=$1
declare -r FILE=$2
declare -r HINT=$3
declare -r DEST='192.168.1.3'
declare -r ERR_NOMODULE=2

# Prepend the used module to the image file name
curl --connect-timeout 30 -T "$FILE" --silent "ftp://$DEST/${MODULE}__${FILE##*/}" || exit $ERR_NOMODULE

echo "Captcha from module '$MODULE' with hint '$HINT'" >&2
read -r -t 900 -p 'Enter code: ' RESPONSE || exit $ERR_NOMODULE
echo "$RESPONSE"

exit 0
```

Database using image hash as key:

```shell
#!/bin/sh
#
# Back to february 2009, Megaupload was using 4-character rotation captchas.
# For example:
# $ sqlite3 captchas.db
# sqlite> CREATE TABLE mu (md5sum text unique not null, captcha text not null);
# sqlite> INSERT INTO mu VALUES('fd3b2381269d702eccc509b8849e5b0d', 'RHD8');
# sqlite> INSERT INTO mu VALUES('04761dbbe2a45ca6720755bc324dd19c', 'EFC8');
# sqlite> .exit

if [ "$1" = megaupload ]; then
  DB="$HOME/captchas.db"
  MD5=$(md5sum -b "$1" | cut -c-32)
  if VAL=$(sqlite3 "$DB" "SELECT captcha FROM mu WHERE md5sum=\"$MD5\""); then
    echo "$VAL"
    exit 0
  fi
fi
exit 2
```

## Plowdown advanced use

### Hooks

It is possible to execute your own script before and after call to module download function. 
Related command-line switches are `--run-before` and `--run-after`.

Possible usage:
- (before) Check (with *plowprobe*) if a file has already been downloaded (same filename, same file size/hash)
- (before) Inject your own cookie
- (after) Unrar archives
- (after) Add `--skip-final` command-line switch and do your custom final link download


Example 1: Skip all links coming from HotFile hoster

```shell
$ cat drophf.sh
#!/bin/bash
# $1: module name
# $2: download URL
# $3: cookie (empty) file given to download module function
# You can print messages to stderr. stdout will be trashed
declare -r ERR_NOMODULE=2
if [ "$1" = 'hotfile' ]; then
    echo "===[script skipping $2](Pre-processing)===" >&2
    exit $ERR_NOMODULE
fi
exit 0

$ plowdown --run-before ./drophf.sh -m list_of_links.txt
```

Example 2: Use `wget` for final download (with possible required cookie file for last download)

```shell
$ cat finalwget.sh
#!/bin/bash
# $1: module name
# $2: download URL
# $3: cookie file fulfilled by download module function
# $4: final download URL
# $5: final filename (no path: --output-directory is ignored)
# You can print messages to stderr. stdout will be trashed
echo "===[script for $1](Post-processing)===" >&2
echo "Temporary cookie file: $3" >&2
wget --no-verbose --load-cookies $3 -O $5 $4

$ plowdown --skip-final --run-after ./finalwget.sh http://www.mediafire.com/?k10t0egmhi23f
```

Example 3: Use multiple connections for final download (usually only for premium account users)

```shell
$ cat finalaria.sh
#!/bin/bash
aria2c -x2 $4

$ plowdown -a user:password --skip-final --run-after ./finalaria.sh http://depositfiles.com/files/fv2u9xqya
```

## Miscellaneous

### Additional cURL settings

For all network operations, Plowshare is relying on cURL. You can tweak some advanced settings if necessary.

For example (enforce IPv6):
```shell
echo 'ipv6' >>~/.curlrc
```

Use Plowshare with a SOCKS proxy:
```shell
ssh -f -N -D localhost:3128 user@my.proxy.machine.org
echo 'socks5=localhost:3128' >>~/.curlrc
```

Note: As Plowshare is dealing with verbose, be sure (if present) to have these cURL's options commented:
```shell
#verbose
#silent
#show-error
```

### Known limitations

For historical reasons or design choices, there are several known limitations to Plowshare.

1. You cannot enter through command-line several credentials for different hosts. 
   It's because the modules option `-a`, `--auth`, `b` or `--auth-free` have the same switch name. 
   But you can do it with the configuration file.
2. Same restriction for passwords (*plowdown*). Only one password can be defined with `-p`, `--link-password` switch name.
   If you don't specify this option and link (module) requests it, you'll be prompted for one.

### Implement your own modules

Plowshare exports a set of API to help text and HTML processing.
It is designed to be as simple as possible to develop new modules.
A module must be written in shell with portability in mind; one module matches one website.

A guide is available here:
http://code.google.com/p/plowshare/wiki/NewModules
API list is here:
http://code.google.com/p/plowshare/wiki/NewModules2

A common approach is to read existing modules source code.

## License

Plowshare is made available publicly under the GNU GPLv3 License.
Full license text is available in COPYING file.
