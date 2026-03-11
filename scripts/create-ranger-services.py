from apache_ranger.model.ranger_service import RangerService
from apache_ranger.client.ranger_client import RangerClient
from json import JSONDecodeError

ranger_client = RangerClient('http://ranger:6080', ('admin', 'rangerR0cks!'))


def service_not_exists(service):
    try:
        svc = ranger_client.get_service(service.name)
        return svc is None
    except JSONDecodeError:
        # Treat a decode error as "service not found" so we attempt creation
        return True


kafka = RangerService({'name': 'dev_kafka', 'type': 'kafka',
                       'configs': {'username': 'kafka', 'password': 'kafka',
                                   'zookeeper.connect': 'ranger-zk.example.com:2181',
                                   'policy.download.auth.users': 'kafka',
                                   'tag.download.auth.users': 'kafka',
                                   'setup.additional.default.policies': 'true',
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
