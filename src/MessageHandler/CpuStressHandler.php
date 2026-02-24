<?php

namespace App\MessageHandler;

use App\Message\CpuStressMessage;
use App\Service\JobTracker;
use Symfony\Component\Messenger\Attribute\AsMessageHandler;

#[AsMessageHandler]
final class CpuStressHandler
{
    public function __construct(private JobTracker $tracker) {}

    public function __invoke(CpuStressMessage $message): void
    {
        $job = $this->tracker->markProcessing($message->jobUuid);
        if (!$job) {
            return;
        }

        try {
            $this->tracker->updateProgress($job, 0, "Starting CPU stress ({$message->algorithm}) for {$message->durationSeconds}s");

            $endTime = time() + $message->durationSeconds;
            $startTime = time();
            $primesFound = 0;
            $piValue = 0.0;
            $n = 2;
            $lastReportedPct = -1;

            while (time() < $endTime) {
                if ($message->algorithm === 'primes') {
                    if ($this->isPrime($n)) {
                        $primesFound++;
                    }
                    $n++;
                } else {
                    $piValue = $this->computePiIterations(100_000, $piValue, $n);
                    $n += 100_000;
                }

                $elapsed = time() - $startTime;
                $pct = (int)(($elapsed / $message->durationSeconds) * 100);
                if ($pct !== $lastReportedPct && $pct % 10 === 0 && $pct > 0) {
                    $detail = $message->algorithm === 'primes'
                        ? "primes found so far: {$primesFound}"
                        : "pi approximation: " . number_format($piValue * 4, 10);
                    $this->tracker->updateProgress($job, $pct, "Progress: {$pct}% - {$detail}");
                    $lastReportedPct = $pct;
                }
            }

            $result = $message->algorithm === 'primes'
                ? "Found {$primesFound} primes up to {$n}"
                : "Pi approximated to " . number_format($piValue * 4, 15) . " after {$n} iterations";

            $this->tracker->markCompleted($job, $result);
        } catch (\Throwable $e) {
            $this->tracker->markFailed($job, $e->getMessage());
            throw $e;
        }
    }

    private function isPrime(int $n): bool
    {
        if ($n < 2) return false;
        for ($i = 2, $s = (int)sqrt($n); $i <= $s; $i++) {
            if ($n % $i === 0) return false;
        }
        return true;
    }

    private function computePiIterations(int $iterations, float $currentSum, int $startIndex): float
    {
        for ($i = $startIndex; $i < $startIndex + $iterations; $i++) {
            $currentSum += ((-1) ** $i) / (2 * $i + 1);
        }
        return $currentSum;
    }
}
