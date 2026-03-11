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

#
# This script builds Apache Ranger from source inside a Docker container.
#

cd /home/ranger/git

if [ "${BUILD_HOST_SRC}" == "true" ]
then
  SRC_DIR=/home/ranger/src
else
  if [ ! -d ranger ]
  then
    git clone ${GIT_URL} -b ${BRANCH} ranger
  fi
  SRC_DIR=/home/ranger/git/ranger
fi

cd ${SRC_DIR}

if [ "${SKIPTESTS}" == "true" ]
then
  MAVEN_OPTS="-DskipTests"
else
  MAVEN_OPTS=""
fi

mvn -B ${MAVEN_OPTS} clean package -pl :ranger-distro -am ${PROFILE:+-P "$PROFILE"} -Dranger.version=${RANGER_VERSION}

STATUS=$?

if [ ${STATUS} -eq 0 ]
then
  echo "Build SUCCESS"
  ls -la ${SRC_DIR}/target/

  cp ${SRC_DIR}/target/ranger-${RANGER_VERSION}-admin.tar.gz          /home/ranger/dist/
  cp ${SRC_DIR}/target/ranger-${RANGER_VERSION}-usersync.tar.gz       /home/ranger/dist/
  cp ${SRC_DIR}/target/ranger-${RANGER_VERSION}-tagsync.tar.gz        /home/ranger/dist/
  cp ${SRC_DIR}/target/ranger-${RANGER_VERSION}-kafka-plugin.tar.gz   /home/ranger/dist/

  echo ${RANGER_VERSION} > /home/ranger/dist/version

  echo "Artifacts copied to /home/ranger/dist/"
else
  echo "Build FAILED!"
  exit 1
fi
