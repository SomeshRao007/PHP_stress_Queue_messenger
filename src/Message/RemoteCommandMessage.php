<?php

namespace App\Message;

final readonly class RemoteCommandMessage
{
    public function __construct(
        public string $jobUuid,
        public string $host,
        public string $username,
        public string $password,
        public string $command,
        public int    $port = 22,
        public int    $timeout = 30,
    ) {}
}
