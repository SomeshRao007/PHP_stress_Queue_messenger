<?php

namespace App\Message;

final readonly class IdleWaitMessage
{
    public function __construct(
        public string $jobUuid,
        public int    $durationSeconds = 300,
        public int    $checkIntervalSeconds = 10,
    ) {}
}
