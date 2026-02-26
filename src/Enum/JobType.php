<?php

namespace App\Enum;

enum JobType: string
{
    case CpuStress  = 'cpu_stress';
    case S3Backup   = 's3_backup';
    case SshCommand = 'ssh_command';
    case IdleWait   = 'idle_wait';

    public function label(): string
    {
        return match ($this) {
            self::CpuStress  => 'CPU Stress Test',
            self::S3Backup   => 'S3 Backup (Data Transfer)',
            self::SshCommand => 'Remote SSH Command',
            self::IdleWait   => 'Idle Wait (Keep-Alive)',
        };
    }
}
