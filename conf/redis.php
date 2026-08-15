<?php
    header("Content-Type:text/html;charset=utf-8");
    if (!class_exists('redis')) {
        echo 'PHP redis extension was not installed';
        exit;
    }

    // 连接本机 Redis 服务。
    $redis=new Redis();
    try {
        $redis->connect('127.0.0.1', 6379);
        //$redis->auth('password'); // 启用认证时，将 password 改为实际密码。
        // 显示服务端版本。
        echo "Redis Server version:  ". $redis->info()['redis_version'] ."<br />";

        // 写入并读取演示数据。
        $redis->set('key1', 'This is first value');
        echo "Get key1 value: " . $redis->get('key1') ."<br />";

        // 删除演示数据。
        $redis->del('key1');
        echo "Get key1 value: " . $redis->get('key1') . "<br />";
    } catch (Exception $e) {
        echo "Cannot connect to Redis server: " .$e->getMessage(). "<br />";
    }

?>
Redis Test tools for LNMP 一键安装包
