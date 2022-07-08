{% if pillar["pmm"] is defined %}
docker_install_00:
  file.directory:
    - name: /etc/docker
    - mode: 700

docker_install_01:
  file.managed:
    - name: /etc/docker/daemon.json
    - contents: |
        {"iptables": false}
docker_install_1:
  pkgrepo.managed:
    - humanname: Docker CE Repository
    - name: deb [arch=amd64] https://download.docker.com/linux/{{ grains["os"]|lower }} {{ grains["oscodename"] }} stable
    - file: /etc/apt/sources.list.d/docker-ce.list
    - key_url: https://download.docker.com/linux/{{ grains["os"]|lower }}/gpg

docker_install_2:
  pkg.installed:
    - refresh: True
    - reload_modules: True
    - pkgs: 
        - docker-ce: '{{ pillar["pmm"]["docker-ce_version"] }}*'
        - python3-pip
                
docker_pip_install:
  pip.installed:
    - name: docker-py >= 1.10
    - reload_modules: True

docker_install_3:
  service.running:
    - name: docker

docker_install_4:
  cmd.run:
    - name: 'systemctl restart docker'
    - onchanges:
        - file: /etc/docker/daemon.json

acme_cert:
  cmd.run:
    - shell: /bin/bash
    - name: "/opt/acme/home/{{ pillar["pmm"]["acme_account"] }}/verify_and_issue.sh percona_pmm {{ pillar["pmm"]["name"] }}"

percona_pmm_config:
  file.managed:
    - name: /opt/pmm/{{ pillar["pmm"]["name"] }}/etc/grafana/grafana.ini
    - user: root
    - group: root
    - mode: 644
    - contents: {{ pillar["pmm"]["config"] | yaml_encode }}
    - makedirs: True

percona_pmm_image:
  cmd.run:
    - name: docker pull {{ pillar["pmm"]["image"] }}

percona_pmm_data_container:
  docker_container.running:
    - name: percona-{{ pillar["pmm"]["name"] }}-data
    - user: root
    - image: {{ pillar["pmm"]["image"] }}
    - detach: True
    - volumes:
      - /srv
    - command: /bin/true
    - start: False

percona_pmm_container:
  docker_container.running:
    - name: percona-{{ pillar["pmm"]["name"] }}
    - user: root
    - image: {{ pillar["pmm"]["image"] }}
    - detach: True
    - restart_policy: unless-stopped
    - publish:
        - 0.0.0.0:443:443/tcp
    - binds:
        - /opt/pmm/{{ pillar["pmm"]["name"] }}/etc/grafana:/etc/grafana:rw
        - /opt/acme/cert/{{ pillar["pmm"]["name"] }}:/opt/acme/cert/{{ pillar["pmm"]["name"] }}:rw
    - watch:
        - /opt/pmm/{{ pillar["pmm"]["name"] }}/etc/grafana/grafana.ini
    - volumes_from: percona-{{ pillar["pmm"]["name"] }}-data
    {%- if "env_vars" in pillar["pmm"] %}
    - environment:
      {%- for var_key, var_val in pillar["pmm"]["env_vars"].items() %}
        - {{ var_key }}: {{ var_val }}
      {%- endfor %}
    {%- endif %}


install_pmm_image_components:
  cmd.run:
    - name: docker exec -t percona-{{ pillar["pmm"]["name"] }} bash -c 'yum install libXcomposite libXdamage libXtst cups libXScrnSaver pango atk adwaita-cursor-theme adwaita-icon-theme at at-spi2-atk at-spi2-core cairo-gobject colord-libs  dconf desktop-file-utils ed emacs-filesystem gdk-pixbuf2 glib-networking gnutls gsettings-desktop-schemas gtk-update-icon-cache gtk3 hicolor-icon-theme jasper-libs json-glib libappindicator-gtk3 libdbusmenu libdbusmenu-gtk3 libepoxy liberation-fonts liberation-narrow-fonts liberation-sans-fonts liberation-serif-fonts libgusb libindicator-gtk3 libmodman libproxy libsoup libwayland-cursor libwayland-egl libxkbcommon m4 mailx nettle patch psmisc redhat-lsb-core redhat-lsb-submod-security rest spax time trousers xdg-utils xkeyboard-config alsa-lib -y'

install_pmm_image_plugins:
  cmd.run:
    - name: docker exec -t percona-{{ pillar["pmm"]["name"] }} bash -c 'grafana-cli plugins install {{ pillar["pmm"]["plugins"] }}'

restart_pmm_image:
  cmd.run:
    - name: docker restart percona-{{ pillar["pmm"]["name"] }}

set_pmm_admin_password_for_PMM_versions_prior_to_2.27.0:
  cmd.run:
    - name: docker exec -t percona-{{ pillar["pmm"]["name"] }} bash -c 'grafana-cli --homepath /usr/share/grafana --configOverrides cfg:default.paths.data=/srv/grafana admin reset-admin-password {{ pillar["pmm"]["admin_password"] }}'

change_nginx_cert_1:
  cmd.run:
    - shell: /bin/bash
    - name: docker exec -i percona-{{ pillar["pmm"]["name"] }} sed -i 's/\bssl_certificate\b\(.*\)/ssl_certificate \/opt\/acme\/cert\/{{ pillar["pmm"]["name"] }}\/fullchain.cer;/' /etc/nginx/conf.d/pmm.conf

change_nginx_cert_2:
  cmd.run:
    - shell: /bin/bash
    - name: docker exec -i  percona-{{ pillar["pmm"]["name"] }} sed -i 's/\bssl_certificate_key\b\(.*\)/ssl_certificate_key \/opt\/acme\/cert\/{{ pillar["pmm"]["name"] }}\/{{ pillar["pmm"]["name"] }}.key;/' /etc/nginx/conf.d/pmm.conf

restart container:
  cmd.run:
    - shell: /bin/bash
    - name: docker restart percona-{{ pillar["pmm"]["name"] }}

pmm-data_backup_script:
  file.managed:
    - name: /opt/pmm/{{ pillar["pmm"]["name"] }}/backup_pmm-data.sh
    - contents: |
        #!/bin/bash
        mkdir -p /opt/pmm/{{ pillar["pmm"]["name"] }}/backup
        iptables -A ufw-before-forward -d $(dig +short api.telegram.org) -j REJECT --reject-with icmp-port-unreachable
        docker stop percona-{{ pillar["pmm"]["name"] }}
        docker run --rm --volumes-from percona-{{ pillar["pmm"]["name"] }}-data -v /opt/pmm/{{ pillar["pmm"]["name"] }}/backup:/backup ubuntu tar cvf /backup/percona-{{ pillar["pmm"]["name"] }}-data_srv.tar /srv
        docker start percona-{{ pillar["pmm"]["name"] }}
        sleep 120
        iptables -D ufw-before-forward -d $(dig +short api.telegram.org) -j REJECT --reject-with icmp-port-unreachable
    - mode: 774

pmm-data_restore_script:
  file.managed:
    - name: /opt/pmm/{{ pillar["pmm"]["name"] }}/restore_pmm-data.sh
    - contents: |
        #!/bin/bash
        iptables -A ufw-before-forward -d $(dig +short api.telegram.org) -j REJECT --reject-with icmp-port-unreachable
        docker stop percona-{{ pillar["pmm"]["name"] }}
        docker run --rm --volumes-from percona-{{ pillar["pmm"]["name"] }}-data -v /opt/pmm/{{ pillar["pmm"]["name"] }}/backup:/backup ubuntu bash -c "cd / && tar xvf /backup/percona-{{ pillar["pmm"]["name"] }}-data_srv.tar"
        docker start percona-{{ pillar["pmm"]["name"] }}
        sleep 120
        iptables -D ufw-before-forward -d $(dig +short api.telegram.org) -j REJECT --reject-with icmp-port-unreachable
    - mode: 774

{#
set_pmm_admin_password_for_PMM_versions_2.27.0_and_later:
  cmd.run:
    - name: docker exec -t percona-{{ pillar["pmm"]["name"] }} change-admin-password {{ pillar["pmm"]["admin_password"] }}

dump_db_cron:
  cron.present:
    - name: docker exec -i percona-{{ pillar["pmm"]["name"] }} /bin/bash -c "pg_dump --username postgres pmm-managed" > /var/pmm_backup/pmm-managed.sql
    - user: root
    - minute: 0
    - hour: 3

dump_files_cron:
  cron.present:
    - name: docker cp percona-{{ pillar["pmm"]["name"] }}:/srv /var/pmm_backup/ > /var/log/pmm_backup.log 2>&1
    - user: root
    - minute: 0
    - hour: 3

dir_for_backups:
  file.directory:
    - name: /var/pmm_backup
    - user: root
    - mode: 755
    - makedirs: True
#}
{% endif %}