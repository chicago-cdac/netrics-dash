#!/bin/bash

#
# ensure dependencies on rpi
#
sudo apt-get install -y %dependencies
sudo modprobe tcp_bbr


#
# set up ndt-server
#
if [ ! -f /usr/local/bin/ndt-generate-local-test-certs ]; then
  sudo curl \
    -o /usr/local/bin/ndt-generate-local-test-certs \
    https://raw.githubusercontent.com/%{ndt_server_origin}/%{ndt_server_tag}/gen_local_test_certs.bash

  sudo chmod 775 /usr/local/bin/ndt-generate-local-test-certs
fi

if [ ! -f /usr/local/lib/ndt-server/certs/cert.pem ]; then
  sudo mkdir -p /usr/local/lib/ndt-server
  pushd /usr/local/lib/ndt-server

  sudo install -d certs datadir

  sudo /usr/local/bin/ndt-generate-local-test-certs

  sudo chown root:$(id -g) certs/key.pem
  sudo chmod g+r certs/key.pem

  sudo chown root:$(id -g) datadir
  sudo chmod g+w datadir

  popd

  sudo docker stop ndt7 &>/dev/null
  sudo docker rm ndt7 &>/dev/null

  sudo docker run                                           \
    --detach                                                \
    --restart=always                                        \
    --network=bridge                                        \
    --publish 4444:4444                                     \
    --publish 8888:8888                                     \
    --volume /usr/local/lib/ndt-server/certs:/certs:ro      \
    --volume /usr/local/lib/ndt-server/datadir:/datadir     \
    --read-only                                             \
    --user $(id -u):$(id -g)                                \
    --cap-drop=all                                          \
    --name ndt7                                             \
    %{image_repo}/ndt-server                       \
    -cert /certs/cert.pem                                   \
    -key /certs/key.pem                                     \
    -datadir /datadir                                       \
    -ndt7_addr :4444                                        \
    -ndt5_addr :3001                                        \
    -ndt5_wss_addr :3010                                    \
    -ndt7_addr_cleartext :8888
fi

#
# set up dashboard
#
if [ ! -e /var/lib/netrics-dashboard ]; then
  sudo mkdir -p /var/lib/netrics-dashboard
  sudo chown root:$(id -g) /var/lib/netrics-dashboard
  sudo chmod g+w /var/lib/netrics-dashboard
fi

sudo mkdir -p /var/run/netrics-dashboard

if [ ! -f /var/run/netrics-dashboard/version ] || [ "$(</var/run/netrics-dashboard/version)" != %{version} ]; then
  sudo docker stop netrics-dashboard &>/dev/null
  sudo docker rm netrics-dashboard &>/dev/null

  sudo docker run                                                                          \
    --detach                                                                               \
    --restart=always                                                                       \
    --network=bridge                                                                       \
    --publish 80:8080                                                                      \
    %{dashboard_run_extra}                                                                 \
    --env DATAFILE_PENDING=/var/nm/nm-exp-active-netrics/upload/pending/default/json/      \
    --env DATAFILE_ARCHIVE=/var/nm/nm-exp-active-netrics/upload/archive/default/json/      \
    --env-file /etc/nm-exp-active-netrics/.env                                             \
    --volume /var/lib/netrics-dashboard:/var/lib/dashboard                                 \
    --volume /var/nm:/var/nm:ro                                                            \
    --read-only                                                                            \
    --user $(id -u):$(id -g)                                                               \
    --name netrics-dashboard                                                               \
    %{image_repo}/netrics-dashboard:%{version}

  sudo docker inspect                                         \
    --format="{{.Config.Labels.appversion}}"              \
    netrics-dashboard                                         \
    | sudo tee /var/run/netrics-dashboard/version             \
    | xargs echo netrics-dashboard:
fi

#
# set up data backups
#
cat <<'SCRIPT' | sudo tee /usr/local/bin/local-dashboard > /dev/null
#!/bin/sh
docker run                                                                                 \
  --rm                                                                                   \
  --network=bridge                                                                       \
  --env-file /etc/nm-exp-active-netrics/.env                                             \
  --volume /var/lib/netrics-dashboard:/var/lib/dashboard                                 \
  --volume /var/nm:/var/nm:rw                                                            \
  --read-only                                                                            \
  --user $(id -u):$(id -g)                                                               \
  --name netrics-dashboard-command                                                       \
  %{image_repo}/netrics-dashboard:%{version}                           \
  python -m app.cmd "$@"
SCRIPT

sudo chmod +x /usr/local/bin/local-dashboard

cat <<'SCRIPT' | sudo tee /usr/local/bin/local-dashboard-backupdb > /dev/null
#!/bin/sh

if [ "$1" = --group ]
then
  if [ "$#" -ne 3 ]
  then
    echo "Usage: $0 [--group GROUP] DIRECTORY" >&2
    exit 1
  fi
  GROUP="$2"
  shift 2
elif [ "$#" -ne 1 ]
then
  echo "Usage: $0 [--group GROUP] DIRECTORY" >&2
  exit 1
fi

/usr/local/bin/local-dashboard backupdb --compress "$1"

if [ -n "$GROUP" ]
then
  find "$1/pending/survey" "$1/pending/trial" -type f -not -group $GROUP -print0 | xargs -0 -r chown $USER:$GROUP
  find "$1/pending/survey" "$1/pending/trial" -type f -not -perm -g=w -print0 | xargs -0 -r chmod g+w
fi
SCRIPT

sudo chmod +x /usr/local/bin/local-dashboard-backupdb

cat <<'SCRIPT' | sudo tee /usr/local/bin/ndt7-backup > /dev/null
#!/bin/sh

if [ "$1" = --group ]
then
  if [ "$#" -ne 3 ]
  then
    echo "Usage: $0 [--group GROUP] DIRECTORY" >&2
    exit 1
  fi
  GROUP="$2"
  shift 2
elif [ "$#" -ne 1 ]
then
  echo "Usage: $0 [--group GROUP] DIRECTORY" >&2
  exit 1
fi

SOURCE=/usr/local/lib/ndt-server/datadir/ndt7/
TARGET="$1/pending/ndt7/json/"

if [ ! -d "$TARGET" ]
then
  echo "no such directory: $TARGET" >&2
  exit 1
fi

if [ -n "$GROUP" ]
then
  # correct ownership & permissions
  find "$SOURCE" -type f -print0 | xargs -0 -r chown $USER:$GROUP
  find "$SOURCE" -type f -group $GROUP -print0 | xargs -0 -r chmod g+w

  # move into place
  find "$SOURCE" -type f -group $GROUP -print0 | xargs -0 -r mv -t "$TARGET"
else
  # move into place
  find "$SOURCE" -type f -print0 | xargs -0 -r mv -t "$TARGET"
fi

# clean up source
find "$SOURCE" -mindepth 1 -type d -empty -delete
SCRIPT

sudo chmod +x /usr/local/bin/ndt7-backup

cat <<'CRONTAB' | sudo tee /etc/cron.d/nm-exp-local-dashboard > /dev/null
@midnight  root  /usr/local/bin/local-dashboard-backupdb --group netrics /var/nm/nm-exp-local-dashboard/upload/
@midnight  root  /usr/local/bin/ndt7-backup --group netrics /var/nm/nm-exp-local-dashboard/upload/
CRONTAB

for directory in /var/nm/nm-exp-local-dashboard/upload/pending/survey/csv/ \
                 /var/nm/nm-exp-local-dashboard/upload/pending/trial/csv/  \
                 /var/nm/nm-exp-local-dashboard/upload/archive/survey/csv/ \
                 /var/nm/nm-exp-local-dashboard/upload/archive/trial/csv/  \
                 /var/nm/nm-exp-local-dashboard/upload/pending/ndt7/json/ \
                 /var/nm/nm-exp-local-dashboard/upload/archive/ndt7/json/
do
  sudo mkdir -p $directory
  sudo chmod g+ws $directory
  sudo chown netrics:netrics $directory
done
