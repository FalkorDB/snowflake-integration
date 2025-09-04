# How to use the scripts

## Deploying the app

run `./scripts/setup.sh`

## Cleanup

run `./scripts/cleanup.sh`

## Instantiate

run `./scripts/instansiate.sh`

## Uninstantiate

run `./scripts/uninstantiate.sh`

## View container logs

run `./scripts/logs.sh`

## Call a procedure

```shell
curl -X 'GET' \
  'http://localhost:8080/list_graphs' \
  -H 'accept: application/json'
```
