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
Concerning modules, few are available separately and must be installed in user directory (see [below](#install)).

### Features

- Small footprint (few shell scripts). No java, no python. Run fast on embedded devices.
- Few dependencies and portable. [Bash](https://www.gnu.org/software/bash/) and [cURL](http://curl.haxx.se/) are enough for most hosters.
- Modules (hoster plugins) are simple to write using [Plowshare API](#implement-your-own-modules).
- Support for automatic online captcha solver services.
- Cache mechanism: hoster session or cookie reuse (to avoid relogin).

## Install

See `INSTALL` file for details.

## Usage examples

All scripts share the same verbose options:
- `-v0` (alias: `-q`)
- `-v1` (errors only)
- `-v2` (infos message; default)
- `-v3` (show all messages)
- `-v4` (show all messages, HTML pages and cookies, use this for bug report)

Getting help:
- `--help`
- `--longhelp` (*plowdown* & *plowup* only, prints modules command-line options)

Exhaustive documentation is available in manpages.

All examples below are using fake links.

### Plowdown

Download a file from Rapidshare:

```sh
$ plowdown http://www.rapidshare.com/files/86545320/Tux-Trainer.rar
```

Download a file from Rapidgator using an account (free or premium):

```sh
$ plowdown -a 'myuser:mypassword' http://rapidgator.net/file/49b1b874
```

**Note**: `:` is the separator character for login and password.

Download a list of links (one link per line):

```sh
$ cat file_with_links.txt
# This is a comment
http://depositfiles.com/files/abcdefghi
http://www.rapidshare.com/files/86545320/Tux-Trainer_25-01-2008.rar
$ plowdown file_with_links.txt
```

Download a list of links (one link per line) commenting out (with `#`) those successfully downloaded:

```sh
$ plowdown -m file_with_links.txt
```

**Note**: Files are consecutively downloaded in the order read from input text file.

Download a file from Oron with Death by Captcha service:

```sh
$ plowdown --deathbycaptcha='user:pass' http://oron.com/dw726z0ohky5
```

Download a file from Rapidshare with a proxy (cURL supports `http_proxy` and `https_proxy` environment variables, default port is `3128`):

```sh
$ export http_proxy=http://xxx.xxx.xxx.xxx:80
$ plowdown http://www.rapidshare.com/files/86545320/Tux-Trainer.rar
```

Download a file with limiting the download speed (in bytes per second):

```sh
$ plowdown --max-rate 900K http://www.rapidshare.com/files/86545320/Tux-Trainer.rar
```

**Note**: Accepted prefixes are: `k`, `K`, `Ki`, `M`, `m`, `Mi`.

Download a file from Rapidshare (like firefox: append `.part` suffix to filename while file is being downloaded):

```sh
$ plowdown --temp-rename http://www.rapidshare.com/files/86545320/Tux-Trainer.rar
```

Download a password-protected file from Mediafire:

```sh
$ plowdown -p 'somepassword' http://www.mediafire.com/?mt0egmhietj60iy
```

**Note**: If you don't specify password and link requests it, you'll be prompted (stdin) for one.

Avoid never-ending downloads: limit the number of tries (for captchas) and wait delays for each link:

```sh
$ plowdown --max-retries=4 --timeout=3600 my_big_list_file.txt
```

### Plowup

Upload a single file anonymously to BayFiles:

```sh
$ plowup bayfiles /tmp/foo.bar
```

Upload a bunch of files anonymously to 2Shared (doesn't recurse subdirectories):

```sh
$ plowup 2shared /path/myphotos/*
```

**Note**: `*` is a [wildcard character](http://en.wikipedia.org/wiki/Glob_%28programming%29) expanded by Bash interpreter.

Upload a file to Rapidshare with an account (premium or free)

```sh
$ plowup -a 'myuser:mypassword' rapidshare /path/xxx
```

Upload a file to Mirrorcreator changing uploaded filename:

```sh
$ plowup mirrorcreator /path/myfile.txt:anothername.txt
```

**Note**: `:` is the separator character for local filename and remote filename.

Upload a file to MegaShares (anonymously) and set description:

```sh
$ plowup -d "Important document" megashares /path/myfile.tex
```

Upload a file to Oron anonymously with a proxy:

```sh
$ export http_proxy=http://xxx.xxx.xxx.xxx:80
$ export https_proxy=http://xxx.xxx.xxx.xxx:80
$ plowup oron /path/myfile.txt
```

Abort slow upload (if rate is below limit during 30 seconds):

```sh
$ plowup --min-rate 100k mediafire /path/bigfile.zip
```

Modify remote filenames (example: `foobar.rar` gives `foobar-PLOW.rar`):

```sh
$ plowup --name='%g-PLOW.%x' mirrorcreator *.rar
```

**Remark**: Be aware that cURL is not capable of uploading files containing a comma `,` in their name, so make sure to rename them before using *plowup*.

Use cache over sessions to avoid multiple logins:

```sh
$ plowup --cache=shared -a 'user:pasword' 1fichier file1.zip
$ plowup --cache=shared 1fichier file2.zip
```

On first command line, login stage will be performed and session (token or cookie) will be saved in
`~/.config/plowshare/storage/module-name.txt`.
On second command line, *plowup* will reuse the data stored to bypass login step. You don't have to specify credentials.

**Note**: Only few hosters currently support cache mechanism.

### Plowdel

Delete a file from MegaShares (*delete link* required):

```sh
$ plowdel http://d01.megashares.com/?dl=6EUeDtS
```

Delete files (deletes are successive, not parallel):

```sh
$ plowdel http://d01.megashares.com/?dl=6EUeDtS http://depositfiles.com/rmv/1643181821669253
```

Delete a file from Rapidshare (account is required):

```sh
$ plowdel -a myuser:mypassword http://rapidshare.com/files/293672730/foo.rar
```

### Plowlist

List links contained in a shared folder link and download them all:

```sh
$ plowlist http://www.mediafire.com/?qouncpzfe74s9 > links.txt
$ plowdown -m links.txt
```

List two shared folders (first link is processed, then the second one, this is not parallel):

```sh
$ plowlist http://www.mediafire.com/?qouncpzfe74s9 http://www.sendspace.com/folder/5njdw7
```

**Remark**: Some hosters are handling tree folders, you must specify `-R`/`--recursive` command-line switch to *plowlist* for enabing recursive lisiting.

List some Sendspace web folder. Render results for vBulletin *BB* syntax:

```sh
$ plowlist --printf '[url=%u]%f[/url]%n' http://www.sendspace.com/folder/5njdw7
```

List links contained in a dummy web page. Render results as HTML list:

```sh
$ plowlist --fallback --printf '<li><a href="%u">%u</a></li>%n' \
      http://en.wikipedia.org/wiki/SI_prefix
```

### Plowprobe

Gather public information (filename, file size, file hash, ...) about a link.
No captcha solving is requested.

Filter alive links in a text file:

```sh
$ plowprobe file_with_links.txt > file_with_active_links.txt
```

Custom results format: print links information (filename and size). Shell and [JSON](http://json.org/) output.

```sh
$ plowprobe --printf '#%f (%s)%n%u%n'  http://myhoster.com/files/5njdw7
#foo-bar.rar (134217728)
http://myhoster.com/files/5njdw7
```

```sh
$ plowprobe --printf '{"url":"%U","size":%s}%n' http://myhoster.com/files/5njdw7
{"url":"http:\/\/myhoster.com\/files\/5njdw7","size":134217728}
```

Custom results: print *primary* url (if supported by hosters and implemented by module):

```sh
$ plowprobe --printf='%v%n' http://a5ts8yt25l.1fichier.com/
https://1fichier.com/?a5ts8yt25l
```

Use `-` argument to read from stdin:

```sh
$ plowlist http://pastebin.com/1d82F5sd | plowprobe - > filtered_list.txt
```

## Configuration file

Plowshare looks for `~/.config/plowshare/plowshare.conf` or `/etc/plowshare.conf` files.
Options given at command line can be stored in the file.

Example:
```ini
###
### Plowshare configuration file
### Line syntax: token = value
###

[General]
interface = eth1
captchabhood=cbhuser:cbhpass

rapidshare/a = matt:4deadbeef
mediafire/a = "matt:4 dead beef "
freakshare/b=plowshare:xxxxx

[Plowdown]
timeout=3600
#antigate=49b1b8740e4b51cf51838975de9e1c31

[Plowup]
max-retries=2
mirrorcreator/auth-free = foo:bar
mirrorcreator/count = 5

[Plowlist]
verbose = 3

#[Plowprobe]
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

```sh
#!/bin/bash
# $1: module name
# $2: path to image
# $3: captcha type. For example: "recaptcha", "solvemedia", "digit-4".

declare -r ERR_NOMODULE=2
declare -r ERR_CAPTCHA=7

# We only support uploadhero, otherwise tell Plowshare to solve on its own
if [ "$1" != 'uploadhero' ]; then
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

```sh
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

```sh
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
curl --connect-timeout 30 -T "$FILE" --silent "ftp://$DEST/${MODULE}__${FILE##*/}" || \
    exit $ERR_NOMODULE

echo "Captcha from module '$MODULE' with hint '$HINT'" >&2
read -r -t 900 -p 'Enter code: ' RESPONSE || exit $ERR_NOMODULE
echo "$RESPONSE"

exit 0
```

Database using image hash as key:

```sh
#!/bin/sh
#
# Back to February 2009, Megaupload was using 4-character rotation captchas.
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

```sh
$ cat drophf.sh
#!/bin/bash
# $1: module name
# $2: download URL
# $3: cookie (empty) file given to download module function
# You can print messages to stderr. stdout will be trashed
declare -r ERR_NOMODULE=2
if [ "$1" = 'hotfile' ]; then
    echo "===[Pre-processing script skipping $2]===" >&2
    exit $ERR_NOMODULE
fi
exit 0

$ plowdown --run-before ./drophf.sh -m list_of_links.txt
```

Example 2: Use `wget` for final download (with possible required cookie file for last download)

```sh
$ cat finalwget.sh
#!/bin/bash
# $1: module name
# $2: download URL
# $3: cookie file fulfilled by download module function
# $4: final download URL
# $5: final filename (no path: --output-directory is ignored)
# You can print messages to stderr. stdout will be trashed
echo "===[Post-processing script for $1]===" >&2
echo "Temporary cookie file: $3" >&2
wget --no-verbose --load-cookies $3 -O $5 $4

$ plowdown --skip-final --run-after ./finalwget.sh \
    http://www.mediafire.com/?k10t0egmhi23f
```

Example 3: Use multiple connections for final download (usually only for premium account users)

```sh
$ cat finalaria.sh
#!/bin/bash
aria2c -x2 $4

$ plowdown -a user:password --skip-final --run-after ./finalaria.sh \
    http://depositfiles.com/files/fv2u9xqya
```

## Miscellaneous

### Additional cURL settings

For all network operations, Plowshare is relying on cURL. You can tweak some advanced settings if necessary.

For example (enforce IPv6):
```sh
$ echo 'ipv6' >>~/.curlrc
```

Use Plowshare with a SOCKS proxy:
```sh
$ ssh -f -N -D localhost:3128 user@my.proxy.machine.org
$ echo 'socks5=localhost:3128' >>~/.curlrc
```

**Note**: As Plowshare is dealing with verbose, be sure (if present) to have these cURL's options commented:
```
#verbose
#silent
#show-error
```

### Known limitations

For historical reasons or design choices, there are several known limitations to Plowshare.

1. You cannot enter through command-line several credentials for different hosts. 
   It's because the modules option `-a`, `--auth`, `-b` or `--auth-free` have the same switch name.
   But you can do it with the configuration file.
2. Same restriction for passwords (*plowdown*). Only one password can be defined with `-p`, `--link-password` switch name.

### Implement your own modules

Plowshare exports a set of API to help text and HTML processing.
It is designed to be as simple as possible to develop new modules.
A module must be written in shell with portability in mind; one module matches one website.

- [New module documentation](https://github.com/mcrapet/plowshare/wiki/Modules)
- [API list](https://github.com/mcrapet/plowshare/wiki/API)

A common approach is to read existing modules source code.

## License

Plowshare is made available publicly under the GNU GPLv3 License.
Full license text is available in COPYING file.
