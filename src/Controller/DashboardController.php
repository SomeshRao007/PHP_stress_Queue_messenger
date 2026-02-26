<?php

namespace App\Controller;

use App\Entity\Job;
use App\Enum\JobStatus;
use App\Enum\JobType;
use App\Message\CpuStressMessage;
use App\Message\DataTransferMessage;
use App\Message\IdleWaitMessage;
use App\Message\RemoteCommandMessage;
use App\Repository\JobRepository;
use Doctrine\ORM\EntityManagerInterface;
use Symfony\Bundle\FrameworkBundle\Controller\AbstractController;
use Symfony\Component\HttpFoundation\JsonResponse;
use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;
use Symfony\Component\Messenger\MessageBusInterface;
use Symfony\Component\Routing\Attribute\Route;
use Symfony\Component\Uid\Uuid;

final class DashboardController extends AbstractController
{
    public function __construct(
        private MessageBusInterface $bus,
        private JobRepository $jobRepo,
        private EntityManagerInterface $em,
    ) {}

    #[Route('/', name: 'dashboard', methods: ['GET'])]
    public function index(): Response
    {
        return $this->render('dashboard/index.html.twig', [
            'jobs'     => $this->jobRepo->findRecentJobs(50),
            'jobTypes' => JobType::cases(),
            'defaults' => [
                'ssh_host'  => $this->getParameter('app.ssh_default_host'),
                'ssh_user'  => $this->getParameter('app.ssh_default_user'),
                's3_bucket' => $this->getParameter('app.s3_bucket'),
            ],
        ]);
    }

    #[Route('/job/create', name: 'job_create', methods: ['POST'])]
    public function createJob(Request $request): Response
    {
        $type = JobType::from($request->request->get('job_type'));
        $count = max(1, min(100, (int) $request->request->get('job_count', 1)));
        $params = $request->request->all();

        for ($i = 0; $i < $count; $i++) {
            $uuid = Uuid::v4()->toRfc4122();

            $job = new Job();
            $job->setUuid($uuid);
            $job->setType($type);
            $job->setStatus(JobStatus::Pending);
            $job->setParameters(array_merge($params, ['batch_index' => $i + 1, 'batch_total' => $count]));

            $message = match ($type) {
                JobType::CpuStress  => $this->buildCpuStressMessage($uuid, $request),
                JobType::S3Backup   => $this->buildDataTransferMessage($uuid, $request, $i),
                JobType::SshCommand => $this->buildRemoteCommandMessage($uuid, $request),
                JobType::IdleWait   => $this->buildIdleWaitMessage($uuid, $request),
            };

            $this->em->persist($job);
            $this->bus->dispatch($message);
        }

        $this->em->flush();

        $label = $type->label();
        $this->addFlash('success', "{$count} '{$label}' job(s) dispatched successfully.");
        return $this->redirectToRoute('dashboard');
    }

    #[Route('/job/{id}', name: 'job_show', methods: ['GET'], requirements: ['id' => '\d+'])]
    public function show(Job $job): Response
    {
        return $this->render('dashboard/show.html.twig', ['job' => $job]);
    }

    #[Route('/job/{id}/cancel', name: 'job_cancel', methods: ['POST'], requirements: ['id' => '\d+'])]
    public function cancel(Job $job): Response
    {
        if ($job->getStatus() === JobStatus::Pending) {
            $job->setStatus(JobStatus::Cancelled);
            $job->appendLog('Job cancelled by user.');
            $this->em->flush();

            $conn = $this->em->getConnection();
            $conn->executeStatement(
                "DELETE FROM messenger_messages WHERE body LIKE :uuid",
                ['uuid' => '%' . $job->getUuid() . '%']
            );

            $this->addFlash('info', 'Job cancelled.');
        } else {
            $this->addFlash('warning', 'Only pending jobs can be cancelled.');
        }

        return $this->redirectToRoute('dashboard');
    }

    #[Route('/job/{id}/delete', name: 'job_delete', methods: ['POST'], requirements: ['id' => '\d+'])]
    public function delete(Job $job): Response
    {
        $this->em->remove($job);
        $this->em->flush();
        $this->addFlash('info', 'Job removed.');
        return $this->redirectToRoute('dashboard');
    }

    #[Route('/api/job/{id}/status', name: 'job_status_api', methods: ['GET'], requirements: ['id' => '\d+'])]
    public function statusApi(Job $job): JsonResponse
    {
        return $this->json([
            'id'       => $job->getId(),
            'status'   => $job->getStatus()->value,
            'progress' => $job->getProgress(),
            'log'      => $job->getLog(),
            'result'   => $job->getResult(),
        ]);
    }

    private function buildCpuStressMessage(string $uuid, Request $r): CpuStressMessage
    {
        return new CpuStressMessage(
            jobUuid: $uuid,
            durationSeconds: (int) $r->request->get('duration', 30),
            algorithm: $r->request->get('algorithm', 'primes'),
        );
    }

    private function buildDataTransferMessage(string $uuid, Request $r, int $index = 0): DataTransferMessage
    {
        $baseKey = $r->request->get('s3_key', 'backups/demo.zip');
        $s3Key = $index > 0
            ? preg_replace('/\.zip$/i', "-{$index}.zip", $baseKey)
            : $baseKey;

        return new DataTransferMessage(
            jobUuid: $uuid,
            bucketName: $r->request->get('bucket', $this->getParameter('app.s3_bucket')),
            s3Key: $s3Key,
        );
    }

    private function buildRemoteCommandMessage(string $uuid, Request $r): RemoteCommandMessage
    {
        return new RemoteCommandMessage(
            jobUuid: $uuid,
            host: $this->getParameter('app.ssh_default_host'),
            username: $this->getParameter('app.ssh_default_user'),
            password: $this->getParameter('app.ssh_default_pass'),
            command: $r->request->get('ssh_command', 'uptime'),
            port: (int) $r->request->get('ssh_port', 22),
        );
    }

    private function buildIdleWaitMessage(string $uuid, Request $r): IdleWaitMessage
    {
        return new IdleWaitMessage(
            jobUuid: $uuid,
            durationSeconds: (int) $r->request->get('idle_duration', 300),
            checkIntervalSeconds: (int) $r->request->get('idle_interval', 10),
        );
    }
}
