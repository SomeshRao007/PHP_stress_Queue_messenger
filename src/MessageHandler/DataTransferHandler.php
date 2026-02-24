<?php

namespace App\MessageHandler;

use App\Message\DataTransferMessage;
use App\Service\JobTracker;
use Aws\S3\S3Client;
use League\Flysystem\AwsS3V3\AwsS3V3Adapter;
use League\Flysystem\Filesystem;
use Symfony\Component\Messenger\Attribute\AsMessageHandler;

#[AsMessageHandler]
final class DataTransferHandler
{
    public function __construct(
        private JobTracker $tracker,
        private string $projectDir,
        private string $awsKey,
        private string $awsSecret,
        private string $awsRegion,
        private string $s3Endpoint,
    ) {}

    public function __invoke(DataTransferMessage $message): void
    {
        $job = $this->tracker->markProcessing($message->jobUuid);
        if (!$job) {
            return;
        }

        try {
            $sourceDir = $this->projectDir . '/' . $message->sourceDir;
            $this->tracker->updateProgress($job, 10, 'Preparing dummy data directory...');
            $this->ensureDummyData($sourceDir);

            $this->tracker->updateProgress($job, 30, 'Creating ZIP archive...');
            $zipPath = $this->projectDir . '/var/backup-' . $message->jobUuid . '.zip';
            $this->createZip($sourceDir, $zipPath);
            $fileSize = filesize($zipPath);

            $this->tracker->updateProgress($job, 60, "Uploading to s3://{$message->bucketName}/{$message->s3Key} ({$fileSize} bytes)");

            $clientConfig = [
                'version'     => 'latest',
                'region'      => $this->awsRegion,
                'credentials' => [
                    'key'    => $this->awsKey,
                    'secret' => $this->awsSecret,
                ],
                'use_path_style_endpoint' => true,
            ];

            if ($this->s3Endpoint) {
                $clientConfig['endpoint'] = $this->s3Endpoint;
            }

            $client = new S3Client($clientConfig);
            $adapter = new AwsS3V3Adapter($client, $message->bucketName);
            $filesystem = new Filesystem($adapter);

            $stream = fopen($zipPath, 'rb');
            $filesystem->writeStream($message->s3Key, $stream);
            if (is_resource($stream)) {
                fclose($stream);
            }

            $this->tracker->updateProgress($job, 90, 'Upload complete. Cleaning up...');
            @unlink($zipPath);

            $this->tracker->markCompleted($job, "Uploaded {$message->s3Key} to bucket {$message->bucketName} ({$fileSize} bytes)");
        } catch (\Throwable $e) {
            $this->tracker->markFailed($job, $e->getMessage());
            throw $e;
        }
    }

    private function ensureDummyData(string $dir): void
    {
        if (!is_dir($dir)) {
            mkdir($dir, 0755, true);
        }
        for ($i = 1; $i <= 5; $i++) {
            $file = $dir . "/file_{$i}.txt";
            if (!file_exists($file)) {
                file_put_contents($file, str_repeat("Dummy data line {$i}\n", 1000));
            }
        }
    }

    private function createZip(string $sourceDir, string $zipPath): void
    {
        $zip = new \ZipArchive();
        if ($zip->open($zipPath, \ZipArchive::CREATE | \ZipArchive::OVERWRITE) !== true) {
            throw new \RuntimeException("Cannot create ZIP file: {$zipPath}");
        }

        $files = new \RecursiveIteratorIterator(
            new \RecursiveDirectoryIterator($sourceDir, \FilesystemIterator::SKIP_DOTS),
            \RecursiveIteratorIterator::LEAVES_ONLY
        );

        foreach ($files as $file) {
            $filePath = $file->getRealPath();
            $relativePath = substr($filePath, strlen(realpath($sourceDir)) + 1);
            $zip->addFile($filePath, $relativePath);
        }

        $zip->close();
    }
}
