use role consumer_role;
create application falkordb_app_instance from application package falkordb_app_pkg using version v1;


-- use database consumer_test;
use role consumer_role;
create  compute pool pool_consumer for application falkordb_app_instance
    min_nodes = 1 max_nodes = 1
    instance_family = cpu_x64_s
    auto_resume = true;

grant usage on compute pool pool_consumer to application falkordb_app_instance;
grant usage on warehouse wh_consumer to application falkordb_app_instance;
grant bind service endpoint on account to application falkordb_app_instance;


call falkordb_app_instance.app_public.start_app('POOL_CONSUMER', 'WH_CONSUMER');