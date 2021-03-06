#!/bin/bash

CONFIG_FILE="/etc/samba/smb.conf"
FIRSTTIME=true

if [[ -z "$DISABLE_SOCKET_OPTIONS" ]] ; then
  COMMENT_IT=""
else
  COMMENT_IT="# "
fi

hostname=`hostname`
set -e
cat >"$CONFIG_FILE" <<EOT
[global]
workgroup = WORKGROUP
server string = foofoo
log file = /var/log/samba/log.%m
log level = 1
# Cap the size of the individual log files (in KiB).
max log size = 1000
logging = file
# panic action = /usr/share/samba/panic-action %d
server role = standalone server
obey pam restrictions = yes
map to guest = bad user
min protocol = SMB2
${COMMENT_IT}socket options = TCP_NODELAY SO_RCVBUF=8192 SO_SNDBUF=8192

load printers = no
printing = bsd
printcap name = /dev/null
disable spoolss = yes

EOT

  while getopts ":u:s:h" opt; do
    case $opt in
      h)
        cat <<EOH
Samba server container

ATTENTION: This is a recipe highly adapted to my needs, it might not fit yours.
Deal with local filesystem permissions, container permissions and Samba permissions is a Hell, so I've made a workarround to keep things as simple as possible.
I want avoid that the usage of this conainer would affect current file permisions of my local system, so, I've "synchronized" the owner of the path to be shared with Samba user. This mean that some commitments and limitations must be assumed.

Container will be configured as samba sharing server and it just needs:
 * host directories to be mounted,
 * users (one or more uid:gid:username:usergroup:password tuples) provided,
 * shares defined (name, path, users).

 -u uid:gid:username:usergroup:password         add uid from user p.e. 1000
                                                add gid from group that user belong p.e. 1000
                                                add a username p.e. alice
                                                add a usergroup (wich user must belong) p.e. alice
                                                protected by 'password' (The password may be different from the user's actual password from your host filesystem)

 -s name:path:show:rw:user1[,user2[,userN]]
                              add a share that is accessible as 'name', exposing
                              contents of 'path' directory. 'show' or 'noshow'
                              controls whether this 'name' is browsable or not.
                              this share also has read+write (rw) or read-only (ro)
                              access control for specified logins
                              user1, user2, .., userN

To adjust the global samba options, create a volume mapping to /config

Example:
docker run -d -p 445:445 \\
  -- hostname any-host-name \\ # Optional
  -v /any/path:/share/data \\ # Replace /any/path with some path in your system owned by a real user from your host filesystem
  elswork/samba \\
  -u "1000:1000:alice:alice:put-any-password-here" \\ # At least the first user must match (password can be different) with a real user from your host filesystem
  -u "1001:1001:bob:bob:secret" \\
  -u "1002:1002:guest:guest:guest" \\
  -s "Backup directory:/share/backups:show:rw:alice,bob" \\
  -s "Alice (private):/share/data/alice:show:rw:alice" \\
  -s "Bob (private):/share/data/bob:hidden:rw:bob" \\ # Bob's private share does not show up when user is browsing the shares
  -s "Documents (readonly):/share/data/documents:show:ro:guest,alice,bob"

EOH
        exit 1
        ;;
      u)
        echo -n "Add user "
        IFS=: read uid group username groupname password <<<"$OPTARG"
        echo -n "'$username' "
        if [[ $FIRSTTIME ]] ; then
          id -g "$group" &>/dev/null || id -gn "$groupname" &>/dev/null || addgroup -g "$group" -S "$groupname"
          id -u "$uid" &>/dev/null || id -un "$username" &>/dev/null || adduser -u "$uid" -G "$groupname" "$username" -SHD
          FIRSTTIME=false
        fi
        echo -n "with password '$password' "
        echo "$password" |tee - |smbpasswd -s -a "$username"
        echo "DONE"
        ;;
      s)
        echo -n "Add share "
        IFS=: read sharename sharepath show readwrite users <<<"$OPTARG"
        echo -n "'$sharename' "
        echo "[$sharename]" >>"$CONFIG_FILE"
        echo -n "path '$sharepath' "
        echo "path = \"$sharepath\"" >>"$CONFIG_FILE"

        if [[ "show" = "$show" ]] ; then
          echo -n "browseable "
          # echo "browseable = yes" >>"$CONFIG_FILE" # browseable = yes is the default behavior
        else
          echo -n "not-browseable "
          echo "browseable = no" >>"$CONFIG_FILE"
        fi

#        echo -n "read"
#        if [[ "rw" = "$readwrite" ]] ; then
#          echo -n "+write "
#          echo "read only = no" >>"$CONFIG_FILE"
#          echo "writable = yes" >>"$CONFIG_FILE"
#        else
#          echo -n "-only "
#          echo "read only = yes" >>"$CONFIG_FILE"
#          echo "writable = no" >>"$CONFIG_FILE"
#        fi

        if [[ -z "$users" ]] ; then
          echo -n "for guests: "
          echo "guest ok = yes" >>"$CONFIG_FILE"
          if [[ "rw" = "$readwrite" ]] ; then
            echo "(read-write)"
            echo "read only = no" >>"$CONFIG_FILE"
            echo "force directory mode = 2777" >>"$CONFIG_FILE"
            echo "force create mode = 0666" >>"$CONFIG_FILE"
          else
            echo -n "(read-only)"
            echo "force directory mode = 2775" >>"$CONFIG_FILE"
            echo "force create mode = 0664" >>"$CONFIG_FILE"
          fi
#          echo "public = yes" >>"$CONFIG_FILE"
        else
          echo -n "for users: "
          users=$(echo "$users" |tr "," " ")
          echo -n "$users "
#          echo "guest ok = no" >>"$CONFIG_FILE"
          echo "valid users = $users" >>"$CONFIG_FILE"
#          echo "read list = $users" >>"$CONFIG_FILE"
          if [[ "rw" = "$readwrite" ]] ; then
            echo "(read-write)"
            echo "write list = $users" >>"$CONFIG_FILE"
          else
            echo "(read-only)"
            echo "read list = $users" >>"$CONFIG_FILE"
          fi
          echo "force directory mode = 2770" >>"$CONFIG_FILE"
          echo "force create mode = 0660" >>"$CONFIG_FILE"

        fi
        echo "DONE"
        ;;
      \?)
        echo "Invalid option: -$OPTARG"
        exit 1
        ;;
      :)
        echo "Option -$OPTARG requires an argument."
        exit 1
        ;;
    esac
  done
nmbd -D
exec ionice -c 3 smbd -FS --no-process-group --configfile="$CONFIG_FILE" < /dev/null
