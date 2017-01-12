
# COMMON COMMANDS:


## Install ES Plugins

* Stop ElasticSearch if it is running
* Configure using `elasticsearch.yml`
* Install the following plugins:

```shell

./plugin install mobz/elasticsearch-head
./plugin install -b https://github.com/couchbaselabs/elasticsearch-transport-couchbase/releases/download/2.2.4.0-update1/elasticsearch-transport-couchbase-2.2.4.0-update1.zip

```


## Update Configurations

* Start ElasticSearch
* Run the following commands (applying the template and creating the index `control`)

```shell

curl -X PUT http://localhost:9200/_template/couchbase -d @es_template.json

```


## Backing Up the Database

```shell

cd C:\Program Files\Couchbase\Server\bin
cbbackup http://localhost:8091/ C:/aca_apps/backups/2015-06-02 -u Administrator -p password -b control

```


## Restoring the Database

```shell

cd C:\Program Files\Couchbase\Server\bin
cbrestore C:/aca_apps/backups/2015-06-01 http://Administrator:password@localhost:8091/ --bucket-source=control --bucket-destination=control

```
