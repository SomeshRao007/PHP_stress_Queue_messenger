<?php

namespace App\Message;

final readonly class DataTransferMessage
{
    public function __construct(
        public string $jobUuid,
        public string $bucketName,
        public string $s3Key = 'backups/demo-backup.zip',
        public string $sourceDir = 'var/dummy_data',
    ) {}
}
