# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
ranger-schema-registry-register.py
------------------------------------
One-shot script run by the ranger-schema-registry-init container.

Responsibilities:
  1. Poll Ranger Admin until it is accepting HTTP requests.
  2. Poll Schema Registry until it responds on /subjects.
  3. Create (or verify) the 'dev_schema_registry' service in Ranger.

The script is idempotent: it does nothing if the service already exists.
"""

import time
import requests
from apache_ranger.model.ranger_service import RangerService
from apache_ranger.client.ranger_client import RangerClient
from json import JSONDecodeError

RANGER_URL        = 'http://ranger:6080'
RANGER_AUTH       = ('admin', 'rangerR0cks!')
SCHEMA_REG_URL    = 'http://ranger-schema-registry.example.com:8081'
POLL_INTERVAL_SEC = 10


def wait_for_http(url, label):
    """Block until *url* returns a non-5xx HTTP response."""
    print(f"Waiting for {label} ({url}) ...", flush=True)
    while True:
        try:
            resp = requests.get(url, timeout=5)
            if resp.status_code < 500:
                print(f"  {label} ready (HTTP {resp.status_code}).", flush=True)
                return
        except Exception as exc:
            pass
        print(f"  {label} not ready yet – retrying in {POLL_INTERVAL_SEC}s ...",
              flush=True)
        time.sleep(POLL_INTERVAL_SEC)


def service_exists(ranger_client, name):
    try:
        svc = ranger_client.get_service(name)
        return svc is not None
    except JSONDecodeError:
        return False


def main():
    wait_for_http(f'{RANGER_URL}/login.jsp',  'Ranger Admin')
    wait_for_http(f'{SCHEMA_REG_URL}/subjects', 'Schema Registry')

    ranger_client = RangerClient(RANGER_URL, RANGER_AUTH)

    schema_registry_svc = RangerService({
        'name': 'dev_schema_registry',
        'type': 'schema-registry',
        'configs': {
            'username':                       'admin',
            'password':                       'rangerR0cks!',
            # Required by Ranger schema-registry service type validation
            'schema.registry.url':            SCHEMA_REG_URL,
            'schema-registry.authentication': 'simple',
            # Users allowed to download policies from Ranger
            'policy.download.auth.users':     'schema-registry',
            'tag.download.auth.users':        'schema-registry',
            'userstore.download.auth.users':  'schema-registry',
            'ranger.plugin.schema-registry.policy.refresh.synchronous': 'true',
        },
    })

    try:
        if service_exists(ranger_client, 'dev_schema_registry'):
            print('Ranger service dev_schema_registry already exists – skipping.',
                  flush=True)
        else:
            ranger_client.create_service(schema_registry_svc)
            print('Ranger service dev_schema_registry created successfully.',
                  flush=True)
    except Exception as exc:
        print(f'Error creating Ranger service: {exc}', flush=True)


if __name__ == '__main__':
    main()
