<?php
  // Application settings are read from environment variables.
  // Kubernetes injects them from a ConfigMap (settings) and a Secret (password),
  // so nothing sensitive is baked into the image or committed to Git.
  $showServerInfo = getenv('SHOW_SERVER_INFO') ?: 'false';
  $timeZone       = getenv('APP_TIMEZONE') ?: 'Asia/Kolkata';
  $currency       = getenv('APP_CURRENCY') ?: '₹';
  $db_url         = getenv('DB_HOST') ?: 'mysql';
  $db_name        = getenv('DB_NAME') ?: 'mom_pop_db';
  $db_user        = getenv('DB_USER') ?: 'cafe';
  $db_password    = getenv('DB_PASSWORD') ?: '';
?>
