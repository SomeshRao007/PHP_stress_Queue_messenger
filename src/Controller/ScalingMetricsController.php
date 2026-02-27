<?php

namespace App\Controller;

use App\Repository\ScalingMetricRepository;
use Symfony\Bundle\FrameworkBundle\Controller\AbstractController;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Routing\Attribute\Route;

final class ScalingMetricsController extends AbstractController
{
    public function __construct(
        private ScalingMetricRepository $repo,
    ) {}

    #[Route('/scaling-metrics', name: 'scaling_metrics', methods: ['GET'])]
    public function index(Request $request): Response
    {
        $modes = $this->repo->findDistinctModes();
        $selectedMode = $request->query->get('mode', '');

        return $this->render('scaling_metrics/index.html.twig', [
            'modes' => $modes,
            'selectedMode' => $selectedMode,
        ]);
    }

    #[Route('/api/scaling-metrics', name: 'scaling_metrics_api', methods: ['GET'])]
    public function api(Request $request): JsonResponse
    {
        $mode = $request->query->get('mode', '');

        $metrics = $mode
            ? $this->repo->findByMode($mode)
            : $this->repo->findRecent();

        $data = array_map(fn($m) => [
            'recorded_at' => $m->getRecordedAt()->format('Y-m-d H:i:s'),
            'queue_depth' => $m->getQueueDepth(),
            'active_pods' => $m->getActivePods(),
            'pending_pods' => $m->getPendingPods(),
            'completed_jobs' => $m->getCompletedJobs(),
            'failed_jobs' => $m->getFailedJobs(),
            'scaling_mode' => $m->getScalingMode(),
        ], $metrics);

        return $this->json($data);
    }
}
