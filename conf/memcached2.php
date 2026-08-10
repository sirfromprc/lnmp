<?php
header("Content-Type:text/html;charset=utf-8");
if (!class_exists('Memcached')) {
	echo 'PHP Memcached extension was not installed';
	exit;
}

echo "Use PHP Memcached extension.<br />";
//连接
$mem = new Memcached();
$mem->addServer("127.0.0.1", 11211) or die ("Could not connect");

//显示版本
$version = current($mem->getVersion());
echo "Memcached Server version:  ".$version ."<br />";;

//保存数据
$mem->set('key1', 'This is first value', 60);
$val = $mem->get('key1');
echo "Get key1 value: " . $val ."<br />";

//替换数据
$mem->replace('key1', 'This is replace value', 60);
$val = $mem->get('key1');
echo "Get key1 value: " . $val . "<br />";

//保存数组
$arr = array('aaa', 'bbb', 'ccc', 'ddd');
$mem->set('key2', $arr, 60);
$val2 = $mem->get('key2');
echo "Get key2 value: ";
print_r($val2);
echo "<br />";

//删除数据
$mem->delete('key1');
$val = $mem->get('key1');
echo "Get key1 value: " . $val . "<br />";

// 演示页不得清空实例中的全部缓存数据。
// 这个页面部署在网站根目录、无任何鉴权，任何访客一访问就会清空整个
// memcached 实例：不只是本演示写入的两个 key，而是站点所有缓存数据。
// 演示 flush 的价值远小于这个代价。
?>
Memcached Test tools for LNMP 一键安装包
