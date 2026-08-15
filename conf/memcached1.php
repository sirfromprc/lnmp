<?php
header("Content-Type:text/html;charset=utf-8");
if (!class_exists('Memcache')) {
	echo 'PHP Memcache extension was not installed';
	exit;
}

echo "Use PHP Memcache extension.<br />";
// 连接本机 Memcached 服务。
$mem = new Memcache;
$mem->connect("127.0.0.1", 11211) or die ("Could not connect");

// 显示服务端版本。
$version = $mem->getVersion();
echo "Memcached Server version:  ".$version."<br />";

// 写入并读取字符串。
$mem->set('key1', 'This is first value', 0, 60);
$val = $mem->get('key1');
echo "Get key1 value: " . $val ."<br />";

// 替换并读取已有数据。
$mem->replace('key1', 'This is replace value', 0, 60);
$val = $mem->get('key1');
echo "Get key1 value: " . $val . "<br />";

// 写入并读取数组。
$arr = array('aaa', 'bbb', 'ccc', 'ddd');
$mem->set('key2', $arr, 0, 60);
$val2 = $mem->get('key2');
echo "Get key2 value: ";
print_r($val2);
echo "<br />";

// 删除演示数据。
$mem->delete('key1');
$val = $mem->get('key1');
echo "Get key1 value: " . $val . "<br />";

// 演示页不执行全局 flush，避免清空同一实例中的业务缓存。

// 关闭连接。
$mem->close();
?>
Memcached Test tools for LNMP 一键安装包
