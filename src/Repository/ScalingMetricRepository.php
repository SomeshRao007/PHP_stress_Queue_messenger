<?php

namespace App\Repository;

use App\Entity\ScalingMetric;
use Doctrine\Bundle\DoctrineBundle\Repository\ServiceEntityRepository;
use Doctrine\Persistence\ManagerRegistry;

/**
 * @extends ServiceEntityRepository<ScalingMetric>
 */
class ScalingMetricRepository extends ServiceEntityRepository
{
    public function __construct(ManagerRegistry $registry)
    {
        parent::__construct($registry, ScalingMetric::class);
    }

    /** @return ScalingMetric[] */
    public function findByMode(string $mode, int $limit = 500): array
    {
        return $this->createQueryBuilder('m')
            ->where('m.scalingMode = :mode')
            ->setParameter('mode', $mode)
            ->orderBy('m.recordedAt', 'ASC')
            ->setMaxResults($limit)
            ->getQuery()
            ->getResult();
    }

    /** @return ScalingMetric[] */
    public function findRecent(int $limit = 500): array
    {
        return $this->createQueryBuilder('m')
            ->orderBy('m.recordedAt', 'ASC')
            ->setMaxResults($limit)
            ->getQuery()
            ->getResult();
    }

    /** @return string[] */
    public function findDistinctModes(): array
    {
        $result = $this->createQueryBuilder('m')
            ->select('DISTINCT m.scalingMode')
            ->getQuery()
            ->getSingleColumnResult();

        return $result;
    }
}
