<?php

namespace App\Message;

final readonly class CpuStressMessage
{
    public function __construct(
        public string $jobUuid,
        public int    $durationSeconds = 30,
        public string $algorithm = 'primes',
    ) {}
}
