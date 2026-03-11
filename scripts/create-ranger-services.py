#!/usr/bin/env python3

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

from apache_ranger.model.ranger_service import RangerService
from apache_ranger.client.ranger_client import RangerClient
from json import JSONDecodeError

ranger_client = RangerClient('http://ranger:6080', ('admin', 'rangerR0cks!'))


def service_not_exists(service):
    try:
        svc = ranger_client.get_service(service.name)
    except JSONDecodeError:
        return 1
    return 0 if svc is not None else 1


kafka = RangerService({'name': 'dev_kafka', 'type': 'kafka',
    'configs': {'username': 'kafka', 'password': 'kafka',
    'zookeeper.connect': 'ranger-zk.example.com:2181',
    'policy.download.auth.users': 'kafka',
    'tag.download.auth.users': 'kafka',
    'userstore.download.auth.users': 'kafka',
    'ranger.plugin.kafka.policy.refresh.synchronous': 'true'}})

services = [kafka]
for service in services:
    try:
        if service_not_exists(service):
            ranger_client.create_service(service)
            print(f" {service.name} service created!")
    except Exception as e:
        print(f"An exception occurred: {e}")
