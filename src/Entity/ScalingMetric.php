<?php

namespace App\Entity;

use App\Repository\ScalingMetricRepository;
use Doctrine\DBAL\Types\Types;
use Doctrine\ORM\Mapping as ORM;

#[ORM\Entity(repositoryClass: ScalingMetricRepository::class)]
#[ORM\Table(name: 'scaling_metrics')]
class ScalingMetric
{
    #[ORM\Id]
    #[ORM\GeneratedValue]
    #[ORM\Column]
    private ?int $id = null;

    #[ORM\Column(type: Types::DATETIME_IMMUTABLE)]
    private \DateTimeImmutable $recordedAt;

    #[ORM\Column(type: Types::INTEGER)]
    private int $queueDepth = 0;

    #[ORM\Column(type: Types::INTEGER)]
    private int $activePods = 0;

    #[ORM\Column(type: Types::INTEGER)]
    private int $pendingPods = 0;

    #[ORM\Column(type: Types::INTEGER)]
    private int $completedJobs = 0;

    #[ORM\Column(type: Types::INTEGER)]
    private int $failedJobs = 0;

    #[ORM\Column(length: 20)]
    private string $scalingMode = 'unknown';

    #[ORM\Column(type: Types::TEXT, nullable: true)]
    private ?string $notes = null;

    public function getId(): ?int { return $this->id; }
    public function getRecordedAt(): \DateTimeImmutable { return $this->recordedAt; }
    public function setRecordedAt(\DateTimeImmutable $recordedAt): self { $this->recordedAt = $recordedAt; return $this; }
    public function getQueueDepth(): int { return $this->queueDepth; }
    public function setQueueDepth(int $queueDepth): self { $this->queueDepth = $queueDepth; return $this; }
    public function getActivePods(): int { return $this->activePods; }
    public function setActivePods(int $activePods): self { $this->activePods = $activePods; return $this; }
    public function getPendingPods(): int { return $this->pendingPods; }
    public function setPendingPods(int $pendingPods): self { $this->pendingPods = $pendingPods; return $this; }
    public function getCompletedJobs(): int { return $this->completedJobs; }
    public function setCompletedJobs(int $completedJobs): self { $this->completedJobs = $completedJobs; return $this; }
    public function getFailedJobs(): int { return $this->failedJobs; }
    public function setFailedJobs(int $failedJobs): self { $this->failedJobs = $failedJobs; return $this; }
    public function getScalingMode(): string { return $this->scalingMode; }
    public function setScalingMode(string $scalingMode): self { $this->scalingMode = $scalingMode; return $this; }
    public function getNotes(): ?string { return $this->notes; }
    public function setNotes(?string $notes): self { $this->notes = $notes; return $this; }
}
