# README

```
install_name_tool -add_rpath /usr/local/lib/ mvsqlite-preload/libmvsqlite_preload.so
install_name_tool -add_rpath /usr/local/lib/ ./target/release/mvstore
RUST_LOG=error ./target/release/mvstore --data-plane 127.0.0.1:7000 --admin-api 127.0.0.1:7001 --metadata-prefix mvstore-test --raw-data-prefix m \
            --content-cache-size "100000" --cluster /usr/local/etc/foundationdb/fdb.cluster &
curl -f http://localhost:7001/api/create_namespace -d '{"key":"ycsb","metadata":""}'
PRELOAD_PATH="$PWD/mvsqlite-preload/libmvsqlite_preload.so" \
MVSQLITE_PAGE_CACHE_SIZE=50000 \
MVSQLITE_DATA_PLANE=http://localhost:7000 \
RUST_LOG=off \
./res/ci/ycsb.sh ycsb workloada
PRELOAD_PATH="$PWD/../mvsqlite-preload/libmvsqlite_preload.so" MVSQLITE_DATA_PLANE=http://localhost:7000 ./sqlite3 ycsb
```