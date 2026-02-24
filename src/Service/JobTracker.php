<?php

namespace App\Service;

use App\Entity\Job;
use App\Enum\JobStatus;
use App\Repository\JobRepository;
use Doctrine\ORM\EntityManagerInterface;

final class JobTracker
{
    public function __construct(
        private EntityManagerInterface $em,
        private JobRepository $jobRepository,
    ) {}

    public function markProcessing(string $uuid): ?Job
    {
        $job = $this->jobRepository->findByUuid($uuid);
        if (!$job || $job->getStatus() === JobStatus::Cancelled) {
            return null;
        }
        $job->setStatus(JobStatus::Processing);
        $job->setStartedAt(new \DateTimeImmutable());
        $this->em->flush();
        return $job;
    }

    public function updateProgress(Job $job, int $percent, string $logLine = ''): void
    {
        $job->setProgress(min(100, $percent));
        if ($logLine) {
            $job->appendLog($logLine);
        }
        $this->em->flush();
    }

    public function markCompleted(Job $job, string $result = ''): void
    {
        $job->setStatus(JobStatus::Completed);
        $job->setProgress(100);
        $job->setCompletedAt(new \DateTimeImmutable());
        $job->setResult($result);
        $job->appendLog('Job completed successfully.');
        $this->em->flush();
    }

    public function markFailed(Job $job, string $error): void
    {
        $job->setStatus(JobStatus::Failed);
        $job->setCompletedAt(new \DateTimeImmutable());
        $job->setResult('ERROR: ' . $error);
        $job->appendLog('Job FAILED: ' . $error);
        $this->em->flush();
    }
}
