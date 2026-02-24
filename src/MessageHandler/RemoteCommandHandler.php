<?php

namespace App\MessageHandler;

use App\Message\RemoteCommandMessage;
use App\Service\JobTracker;
use phpseclib3\Net\SSH2;
use Symfony\Component\Messenger\Attribute\AsMessageHandler;

#[AsMessageHandler]
final class RemoteCommandHandler
{
    public function __construct(private JobTracker $tracker) {}

    public function __invoke(RemoteCommandMessage $message): void
    {
        $job = $this->tracker->markProcessing($message->jobUuid);
        if (!$job) {
            return;
        }

        try {
            $this->tracker->updateProgress($job, 10, "Connecting to {$message->host}:{$message->port}...");

            $ssh = new SSH2($message->host, $message->port);
            $ssh->setTimeout($message->timeout);

            if (!$ssh->login($message->username, $message->password)) {
                throw new \RuntimeException("SSH authentication failed for {$message->username}@{$message->host}");
            }

            $this->tracker->updateProgress($job, 40, "Connected. Running remote command...");

            $output = $ssh->exec($message->command);
            $exitStatus = $ssh->getExitStatus();

            $this->tracker->updateProgress($job, 80, "Command finished with exit code: {$exitStatus}");

            if ($exitStatus !== 0 && $exitStatus !== false) {
                $stderr = $ssh->getStdError() ?? '';
                $this->tracker->markFailed($job, "Exit code {$exitStatus}. Stderr: {$stderr}\nStdout: {$output}");
            } else {
                $this->tracker->markCompleted($job, $output ?: '(no output)');
            }

            $ssh->disconnect();
        } catch (\Throwable $e) {
            $this->tracker->markFailed($job, $e->getMessage());
            throw $e;
        }
    }
}
