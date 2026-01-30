const fs = require('fs');

module.exports = async ({ github, context, core }) => {
  // Find the Olympix output file (pattern: code_analysis_*.json)
  let jsonFile;
  try {
    const files = fs.readdirSync('.');
    jsonFile = files.find(f => f.startsWith('code_analysis_') && f.endsWith('.json'));
    
    if (!jsonFile) {
      console.log('No Olympix output file found (code_analysis_*.json)');
      return;
    }
    console.log(`Found output file: ${jsonFile}`);
  } catch (e) {
    console.log('Error reading directory:', e.message);
    return;
  }

  // Read the JSON output
  let files;
  try {
    const raw = fs.readFileSync(jsonFile, 'utf8');
    files = JSON.parse(raw);
    if (!Array.isArray(files)) {
      files = files.results || files.files || [files];
    }
  } catch (e) {
    console.log('Invalid JSON:', e.message);
    return;
  }

  // Flatten all bugs from all files
  const allIssues = [];
  for (const file of files) {
    for (const bug of (file.bugs || [])) {
      allIssues.push({
        path: file.path,
        ...bug
      });
    }
  }

  if (allIssues.length === 0) {
    console.log('No security issues found');
    
    await github.rest.checks.create({
      owner: context.repo.owner,
      repo: context.repo.repo,
      name: 'Olympix Security Scan',
      head_sha: context.sha,
      status: 'completed',
      conclusion: 'success',
      output: {
        title: 'No security issues found',
        summary: 'Olympix security scan completed with no issues detected.'
      }
    });
    return;
  }

  // Count by severity
  const severityCounts = { High: 0, Medium: 0, Low: 0 };
  allIssues.forEach(i => {
    const sev = i.severity || 'Unknown';
    if (severityCounts[sev] !== undefined) {
      severityCounts[sev]++;
    }
  });

  // Build summary comment
  let comment = '## Olympix Security Scan Results\n\n';
  comment += `Found **${allIssues.length}** issue(s) across **${files.length}** file(s)\n\n`;

  // Severity summary
  comment += '### Summary\n';
  if (severityCounts.High > 0) comment += `- High: ${severityCounts.High}\n`;
  if (severityCounts.Medium > 0) comment += `- Medium: ${severityCounts.Medium}\n`;
  if (severityCounts.Low > 0) comment += `- Low: ${severityCounts.Low}\n`;
  comment += '\n';

  // Group issues by file
  comment += '### Details\n\n';
  for (const file of files) {
    if (!file.bugs || file.bugs.length === 0) continue;

    comment += `<details>\n<summary><strong>${file.path}</strong> (${file.bugs.length} issues)</summary>\n\n`;
    comment += '| Line | Severity | Confidence | Description |\n';
    comment += '|------|----------|------------|-------------|\n';

    for (const bug of file.bugs) {
      const description = bug.olympixUrl
        ? `[${bug.description}](${bug.olympixUrl})`
        : bug.description;

      comment += `| ${bug.line}:${bug.column} | ${bug.severity} | ${bug.confidence} | ${description} |\n`;
    }
    comment += '\n</details>\n\n';
  }

  // Post comment on PR
  if (context.payload.pull_request) {
    const { data: comments } = await github.rest.issues.listComments({
      owner: context.repo.owner,
      repo: context.repo.repo,
      issue_number: context.payload.pull_request.number
    });

    const existingComment = comments.find(c =>
      c.user.type === 'Bot' && c.body.includes('Olympix Security Scan Results')
    );

    if (existingComment) {
      await github.rest.issues.updateComment({
        owner: context.repo.owner,
        repo: context.repo.repo,
        comment_id: existingComment.id,
        body: comment
      });
    } else {
      await github.rest.issues.createComment({
        owner: context.repo.owner,
        repo: context.repo.repo,
        issue_number: context.payload.pull_request.number,
        body: comment
      });
    }
  }

  // Create check run with inline annotations
  const annotations = allIssues.slice(0, 50).map(issue => ({
    path: issue.path,
    start_line: issue.line,
    end_line: issue.line,
    annotation_level: issue.severity === 'High' ? 'failure' : 'warning',
    message: `[${issue.severity}/${issue.confidence}] ${issue.description}`,
    title: issue.severity
  }));

  const hasHighSeverity = severityCounts.High > 0;

  // Check run fails if high severity issues, workflow continues
  await github.rest.checks.create({
    owner: context.repo.owner,
    repo: context.repo.repo,
    name: 'Olympix Security Scan',
    head_sha: context.sha,
    status: 'completed',
    conclusion: hasHighSeverity ? 'failure' : 'success',
    output: {
      title: `Found ${allIssues.length} issue(s): ${severityCounts.High} high, ${severityCounts.Medium} medium, ${severityCounts.Low} low`,
      summary: comment,
      annotations: annotations
    }
  });

  // Log result but don't fail the workflow
  if (hasHighSeverity) {
    console.log(`Found ${severityCounts.High} high severity issues - check run marked as failed`);
  }
};
