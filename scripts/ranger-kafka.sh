#!/bin/bash

# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

if [ "${OS_NAME}" = "UBUNTU" ]; then
  service ssh start
fi

if [ ! -e ${KAFKA_HOME}/.setupDone ]
then
  if [ "${OS_NAME}" = "RHEL" ]; then
    ssh-keygen -A
    /usr/sbin/sshd
  fi

  su -c "[ -f ~/.ssh/id_rsa ] || ssh-keygen -t rsa -P '' -f ~/.ssh/id_rsa" kafka
  su -c "cat ~/.ssh/id_rsa.pub >> ~/.ssh/authorized_keys" kafka
  su -c "chmod 0600 ~/.ssh/authorized_keys" kafka

  # pdsh is unavailable with microdnf in rhel based image.
  echo "ssh" > /etc/pdsh/rcmd_default

  if "${RANGER_SCRIPTS}"/ranger-kafka-setup.sh;
  then
    # Fix: XmlConfigChanger writes 'NONE' for JAAS loginModuleName tokens,
    # but Ranger audit library treats 'NONE' as a literal class name and fails.
    # Clear loginModuleName and loginModuleControlFlag so the Kerberos path is
    # skipped when connecting to a non-Kerberized Solr for audit.
    AUDIT_XML="${KAFKA_HOME}/config/ranger-kafka-audit.xml"
    if [ -f "${AUDIT_XML}" ]; then
      python3 - "${AUDIT_XML}" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
ET.register_namespace('', '')
path = sys.argv[1]
tree = ET.parse(path)
root = tree.getroot()
clear_props = {
    'xasecure.audit.jaas.Client.loginModuleName',
    'xasecure.audit.jaas.Client.loginModuleControlFlag',
}
for prop in root.findall('property'):
    name_el = prop.find('name')
    val_el  = prop.find('value')
    if name_el is not None and val_el is not None:
        if name_el.text in clear_props and val_el.text == 'NONE':
            val_el.text = ''
tree.write(path, encoding='unicode', xml_declaration=False)
print("Patched ranger-kafka-audit.xml: cleared JAAS Client login module name.")
PYEOF
    fi
    touch "${KAFKA_HOME}"/.setupDone
  else
    echo "Ranger Kafka Setup Script didn't complete proper execution."
  fi
fi

su -c "cd ${KAFKA_HOME} && CLASSPATH=${KAFKA_HOME}/config KAFKA_OPTS='-Djava.security.auth.login.config=${KAFKA_HOME}/config/kafka_server_jaas.conf' ./bin/kafka-server-start.sh config/server.properties" kafka
