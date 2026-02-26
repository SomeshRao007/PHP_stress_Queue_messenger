<?php

namespace App\MessageHandler;

use App\Message\IdleWaitMessage;
use App\Service\JobTracker;
use Symfony\Component\Messenger\Attribute\AsMessageHandler;

#[AsMessageHandler]
final class IdleWaitHandler
{
    public function __construct(private JobTracker $tracker) {}

    public function __invoke(IdleWaitMessage $message): void
    {
        $job = $this->tracker->markProcessing($message->jobUuid);
        if (!$job) {
            return;
        }

        try {
            $duration = $message->durationSeconds;
            $interval = $message->checkIntervalSeconds;
            $elapsed  = 0;

            $this->tracker->updateProgress($job, 0, "Idle wait started — sleeping for {$duration}s (interval: {$interval}s).");

            while ($elapsed < $duration) {
                $sleepTime = min($interval, $duration - $elapsed);
                sleep($sleepTime);
                $elapsed += $sleepTime;

                $percent = (int) round(($elapsed / $duration) * 100);
                $this->tracker->updateProgress($job, $percent, "Elapsed {$elapsed}s / {$duration}s — idle, no resources consumed.");
            }

            $this->tracker->markCompleted($job, "Idle wait completed after {$duration} seconds.");
        } catch (\Throwable $e) {
            $this->tracker->markFailed($job, $e->getMessage());
            throw $e;
        }
    }
}
